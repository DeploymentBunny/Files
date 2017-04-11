Import-Module C:\Setup\Files\Tools\NANORefImagemodule\NANORefImageModule.psm1 -Verbose -Force
New-VIARefImageNANO -ISOImageFile C:\Setup\ISO\WS2016_EVAL.iso -WimIndex 2 -PackagesFolder C:\Setup\Packages\WS2016 -WimFileSource C:\Setup\WIM\NanoServer.wim -WimFileDestination C:\Setup\WIM\NanoServerU.wim -WIMMountFolder C:\Mount -Verbose
Add-VIARefImageNANOFeatures -ISOImageFile C:\Setup\ISO\WS2016_EVAL.iso -WimFile C:\Setup\WIM\NanoServerU.wim -WIMMountFolder C:\Mount -NanoPackages C:\Setup\Packages\NANO -FeatureSet Compute -VM
