#!/usr/bin/php
<?php
# I needed something that could bulk delete entire TV series quickly and easily. Here it is.

if ($title = @$argv[1]) {

	# https://github.com/bevhost/phplib/blob/master/inc/db_pdo.inc
	include("/usr/share/phplib/db_pdo.inc");  

	class DB_mythtv extends DB_Sql {
	  var $Host     = "127.0.0.1";
	  var $Database = "mythconverg";
	  var $User     = "mythtv";
	  var $Password = "15HAluNb";
	}

	$db = new DB_mythtv;

	$db->query("UPDATE recorded SET recgroup='Deleted', autoexpire=9999 WHERE title=".$db->quote($title));
	echo $db->affected_rows();
	echo " $title recordings deleted.\n";

} else echo "Usage: $argv[0] \"Program Title\"\n";

?>
