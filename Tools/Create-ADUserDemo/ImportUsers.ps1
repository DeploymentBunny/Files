#Read data from Bootstrap XML
$settings = "C:\setup\Files\Tools\Create-ADUserDemo\settings.xml"
[xml]$settings = Get-Content $BootstrapFile -ErrorAction Stop

$Users = $settings.Settings.Users.User | Where-Object -Property Active -EQ $True
Foreach($User in $Users){
    $User
}
