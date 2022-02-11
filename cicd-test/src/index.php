<?php
$headers =  getallheaders();
foreach($headers as $key=>$val){
  echo $key . ': ' . $val . '<br>';
}