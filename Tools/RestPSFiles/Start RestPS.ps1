# Start the RestPS
$RestPSparams = @{
             RoutesFilePath = 'C:\RestPS\endpoints\RestPSRoutes.json'
             Port = '8080'
         }
 Start-RestPSListener @RestPSparams