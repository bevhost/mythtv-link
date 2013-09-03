#!/usr/bin/env ruby

# Link mythtv recordings to have more readable filenames so a remote streamer
# can play the mythtv files without using the Myth protocol.
#
# Based on mythlink.pl from Dale Gass
#
# Features:
#   - configurable link filename formats
#   - uses MythXML API instead of internal MySQL commands to make porting
#     to different MythTV versions easier
#   - can use hard links instead of symbolic links
#     (NFS client I am using [PlayOn!HD mini] has problems with symlinks)
#   - allow directory structure in the destination filenames
#   - incremental updates instead of recreating all links to not disturbe
#     the players currently playing any stream.
#
# Current limitations:
#   - probably only supports MythTV backend version 0.23.1 / 0.22-fixes
#     (but easy to extend to different versions)
#   - scripts must be run on backend
#
# R. Nijlunsing <rutger.nijlunsing@gmail.com>

class Config
    attr_accessor :mythtv_storage_path, :stream_ext
    def initialize; yield self; end
end

class DestinationConfig
    attr_accessor :enabled, :dest_path, :use_symlink, :link_format
    def initialize
	# Sensible defaults:
	@enabled = true
	@use_symlink = true
	yield self
    end
end

############## Global configuration
config = Config.new { |c|
    # Directory containing all streams recorded by MythTV backend:
    c.mythtv_storage_path = "/var/video"
    # File extension of all stream files in storage:
    c.stream_ext = ".mpg"
}
# Each recording can be linked to one or more destinations.
# Those destinations are listed below:
destinations = [
    DestinationConfig.new { |d|
	# Set to false to disable this destination:
	d.enabled = true
	# Destination directory to create the links in:
	d.dest_path = "/var/video/tv/"
	# Format string to use to create the link filename. This is an ERB template:
	d.link_format = "<%=recgroup%>/"+
	    "<%=title.tr('^A-Za-z0-9 .-', '_')%>/" +
	    "<%=starttime.strftime('%m%d %H%M')%>" +
	    "<%=' ' + subtitle.tr('^A-Za-z0-9 .-', '_') if !subtitle.empty?%>" +
	    " (<%=duration%>m)"
	# If true, use symlinks. If false, use hardlinks. If unsure, set to
	# true since symlinks are preferred. The only reason to use hardlinks
	# is when your player cannot handle symbolic links.
	d.use_symlink = false
    },
    DestinationConfig.new { |d|
	d.enabled = false
	d.dest_path = "/srv/video_link/rhp1"
	d.link_format = "../All/<%=starttime.strftime('%m%d %H%M')%> - <%=title%>"
	d.use_symlink = true
    },
    DestinationConfig.new { |d|
	d.enabled = false
	d.dest_path = "/srv/video_link/rhp2"
	d.link_format = "../<%=recgroup%>/All/<%=starttime.strftime('%m%d %H%M')%> - <%=title%>"
	d.use_symlink = true
    },
    DestinationConfig.new { |d|
	d.enabled = false
	d.dest_path = "/srv/video_link/rhp3"
	d.link_format = "../<%=recgroup%>/<%=title%>/<%=starttime.strftime('%m%d %H%M')%>"
	d.use_symlink = true
    },
]
############## End of configuration

$verbose = true
# If true, do not delete from MythTV:
$pretend = true

require 'erb'
require 'find'
require 'socket'
require 'fileutils'
require 'time'
require 'net/http'
require 'hpricot'
require 'optparse'

# A recorded program in a file
class Recording
    attr_accessor :chanid, :starttime_str, :endtime_str
    attr_accessor :title, :subtitle, :recgroup, :filename

    # Start- and endtime as Time object:
    def starttime; Time.parse(@starttime_str); end
    def endtime; Time.parse(@endtime_str); end

    # Returns duration of recording in minutes
    def duration; ((endtime()- starttime()) / 60).to_i; end

    def format_link_name(link_format)
	return ERB.new(link_format).result(binding)
    end
end

# Backend protocol. See http://mythtv.org/wiki/Myth_Protocol/Guide
class MythTvProtocol
    def initialize(server)
	@server = server
	@port = 6543
	@socket = nil
	@version = nil     # String. MythTV server version.
    end
    
    def connect
	raise if @socket
	puts "Connecting to #{@server}:#{@port}..." if $verbose
	@socket = TCPSocket.new(@server, @port)
	puts "Connected. Request version from server..." if $verbose
	send("MYTH_PROTO_VERSION x")
	accept = receive()
	raise accept.inspect if accept[0] != "REJECT" || accept.size != 2
	# We're getting back the version we're supposed to speak.
	# So send that back again.
	@socket.close
	@socket = TCPSocket.new(@server, @port)
	@version = accept[1]
	tokens = Hash.new("78B5631E")  # Used by 23056 and 62
	tokens.merge!(
#		"63" => "3875641D",
#		"64" => "8675309J",  	 # we don't support these anymore.
		"72" => "D78EFD6F"
	)
	token = tokens[@version]
	send("MYTH_PROTO_VERSION #{@version} #{token}")
	accept = receive()
	raise "Unsupported MythTV server version: #{accept.inspect}" if accept[0] != "ACCEPT"
	# We're not interesting in any events:
	send("ANN Monitor localhost 0")
	resp = receive()
	raise resp.inspect if resp != ["OK"]
    end
    
    def connected?; @socket != nil; end	
    
    def disconnect
	puts "Disconnecting..."
	send("DONE")
	@socket.close
	@socket = nil
    end

    def send(*cmds)
	str = cmds.join("[]:[]")
	str = ("%-8s" % str.size) + str #+ "\n"
	puts ">>> #{str}"
	@socket.write(str)
    end	
    
    def receive
	size_str = @socket.read(8)
	size = size_str.to_i
	str = @socket.read(size)
	resp = str.split("[]:[]")
	puts "<<< #{resp.inspect}"
	return resp
    end	
    
    def delete_recording(chanid, starttime)
	puts "Delete recording #{chanid} #{starttime}" if $verbose
	send("DELETE_RECORDING #{chanid} #{starttime}")
	resp = receive()
	raise resp.inspect if resp != ["-1"]
    end
end


class LinkedRecording
    # File to watch for deletion:
    attr_accessor :new_fname
    # Attributes needed for the DELETE_RECORDING MythTV command:
    attr_accessor :chanid, :starttime
    # true iff in MythTv database
    attr_accessor :is_in_db
    
    def initialize(new_fname, chanid, starttime)
	@new_fname = new_fname.freeze
	@chanid = chanid.freeze
	@starttime = starttime.freeze
	@is_in_db = true
    end
    
    def matches?(chanid, starttime)
	@chanid == chanid && @starttime == starttime
    end
end

# This uses http://mythtv.org/wiki/Category:MythXML
def mythxml(url)
    mythxmlurl = "http://localhost:6544/Dvr/"
    resp = Net::HTTP.get_response(URI.parse("#{mythxmlurl}/#{url}"))
    raise "Retrieving #{url}: #{resp.code}" if resp.code != "200"
    xml = Hpricot::XML(resp.body)
    return xml
end

# Retrieves the list of current recording from MythTV
def get_recordings()
    puts "Retrieving list of current recordings..." if $verbose
    xml = mythxml("GetRecordedList")
    recordings = (xml / "Programs/Program").map { |program|
	rec = Recording.new
	channel = (program / "Channel").first || raise
	recording = (program / "Recording").first || raise
	rec.chanid = (channel / "ChanId").first.innerHTML || raise
	rec.filename = (program / "FileName").first.innerHTML || raise
	starttime = (recording / "StartTs").first.innerHTML || raise
	endtime = (recording / "EndTs").first.innerHTML || raise
	rec.title = (program / "Title").first.innerHTML || raise
	rec.subtitle = (program / "SubTitle").first.innerHTML || raise
	rec.recgroup = (recording / "RecGroup").first.innerHTML || raise
  
	rec.starttime_str = starttime.delete("^0-9")
	rec.endtime_str = endtime.delete("^0-9")

	puts "Recording #{rec.title} on #{rec.chanid} in #{rec.recgroup} at #{rec.starttime_str}" if $verbose

	rec
    }
    return recordings
end

# Change to owner of streams (if not already the case) so that the
# permissions of the directories created are OK
def change_gid_and_uid(mythtv_storage_path, stream_ext)
    # Determine UID and GID of owner of the saved streams
    stream_glob = "#{mythtv_storage_path}/*#{stream_ext}"
    a_stream_fname = Dir[stream_glob][0]
    if !a_stream_fname
	puts "!!! Could not find any recording at #{stream_glob}"
	exit 1
    end
    a_stream_stat = File.stat(a_stream_fname)
    mythtv_uid = a_stream_stat.uid
    mythtv_gid = a_stream_stat.gid
    if mythtv_gid != Process::Sys.getgid() ||
	    mythtv_uid != Process::Sys.getuid()
	puts "Changing to uid=#{mythtv_uid} gid=#{mythtv_gid}" if $verbose
	Process::Sys.setgid(mythtv_gid)
	Process::Sys.setuid(mythtv_uid)
    end
end

# Returns filename of state-file and its version
def links_state_fname(dest_path)
    return "#{dest_path}/mythtv-link.state", "20101018"
end

# Read previous state
def read_state(dest_path)
    fname, state_version = *links_state_fname(dest_path)
    begin
	version, links = *Marshal.load(File.read(fname))
	links = {} if version != state_version
    rescue Errno::ENOENT, ArgumentError
	links = {}
    end
    puts "Read state file: #{links.size} links" if $verbose
    return links
end

# Write back the new state
def write_state(dest_path, links)
    fname, state_version  = *links_state_fname(dest_path)
    puts "Writing state file: #{links.size} links" if $verbose
    File.open(fname, "wb") { |io|
	io.print Marshal.dump([state_version, links])
    }
end

def mythtv_link(config, dest)
    change_gid_and_uid(config.mythtv_storage_path, config.stream_ext)

    links = read_state(dest.dest_path)

    # Mark all links as 'not in database' till proven otherwise
    links.each_value { |link| link.is_in_db = false }

    mythtv = MythTvProtocol.new("localhost")
    mythtv.connect if $verbose

    if $verbose
	puts "Linking"
	puts "   creating links in #{dest.dest_path}"
	puts "   links will point to #{config.mythtv_storage_path}"
    end
    FileUtils.mkdir_p(dest.dest_path)

    get_recordings().each { |rec|
	# (channel id, starttime) is the unique key identifying a recording:
	key = [rec.chanid, rec.starttime_str]
	old_link = links[key]
	old_link.is_in_db = true if old_link

	# Determine new filename from recording aspects
	new_fname = rec.format_link_name(dest.link_format)
	new_fname = "#{dest.dest_path}/#{new_fname}#{config.stream_ext}"
	puts "new: #{new_fname}" if $verbose
	
	# Create directory in which new file should reside:
	FileUtils.mkdir_p(File.dirname(new_fname))
	
	if old_link && !File.exists?(old_link.new_fname)
	    # This link has been removed, so delete it from MythTV also
	    links.delete(key)
	    mythtv.connect if !mythtv.connected?
	    mythtv.delete_recording(old_link.chanid, old_link.starttime) if !$pretend
	    next
	end
	
	if old_link && old_link.new_fname != new_fname
	    # File got a new name; rename and update. This might
	    # happen when the endtime is updated (once every 10
	    # minutes of recording it seems).
	    puts "Rename: #{old_link.new_fname} -> #{new_fname}" if $verbose
	    File.rename(old_link.new_fname, new_fname)
	    old_link.new_fname = new_fname
	    next
	end
	
	source_stream_fname = 
	    "#{config.mythtv_storage_path}/" +
	#    "#{rec.chanid}_#{rec.starttime_str}#{config.stream_ext}"  #old version did this
	    "#{rec.filename}"  	# new version has the filename in the xml
	if !File.exists?(source_stream_fname)
	    puts "Could not find #{source_stream_fname} (#{rec.title}); skipping..."
	    next
	end

	# We got the filename. Hard link the file.
	begin
	    if dest.use_symlink
		File.symlink(source_stream_fname, new_fname)
	    else
		File.link(source_stream_fname, new_fname)
	    end
	    puts "Created #{new_fname.inspect}" if $verbose
	    links[key] = LinkedRecording.new(new_fname, rec.chanid, rec.starttime_str)
	rescue Errno::EEXIST
	    # Link already exists; ignore error
	end
    }
    mythtv.disconnect if mythtv.connected?
    
    # All links which were accounted for in the database are apparently
    # removed from the database since last time. Also delete them from the fs.
    links.values.each { |link|
	if !link.is_in_db
	    puts "Removed from db, so removing from fs: #{link.new_fname}" if $verbose
	    begin
		File.delete(link.new_fname)
	    rescue Errno::ENOENT
		puts "!!! Could not find file #{link.new_fname}; skipping..."
	    end
	    links.delete([link.chanid, link.starttime])
	end
    }
    
    write_state(dest.dest_path, links)

    # Try to remove now-empty directories (if any):
    puts "Finding and removing empty directories..." if $verbose
    Find.find(*Dir[dest.dest_path + "/*"]) { |fname|
	if File.directory?(fname)
	    begin
		Dir.rmdir(fname)
		puts "Removed empty directory #{fname.inspect}" if $verbose
	    rescue Errno::ENOTEMPTY
	    end
	end
    }
end

#################### Main

opts = OptionParser.new
opts.banner = %Q{
Mythtv-link -- Sync links between MythTV recording files

Add it to your crontab:
*/10 * * * * #{$0}

Options:
}
opts.on("--[no-]verbose") { |v| $verbose = v }
opts.on("--[no-]pretend") { |p| $pretend = p }
opts.on("--help", "-h") { puts opts.to_s; exit 1 }
opts.parse!(ARGV)

dest_paths = destinations.map { |dest| dest.dest_path }
if dest_paths.uniq.size != destinations.size
    puts "!!! Error: all destination must have a unique 'dest_path'."
    puts "!!! Current non-unique 'dest_path' values: #{dest_paths.inspect}"
    exit 1
end

destinations.each { |dest|
    mythtv_link(config, dest) if dest.enabled
}
