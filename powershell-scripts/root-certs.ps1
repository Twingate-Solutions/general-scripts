# This is a super basic script to somewhat automate the process of installing all
# of the trusted root certificates from Windows Update.  This is useful for
# environments where you need to ensure that all devices have the same trusted
# root certificates installed, and you don't want to manually install them on
# each device.  This script will pull down all of the trusted root certificates
# from Windows Update and install them on the device.  

# This script is a bit of a sledgehammer, as it will install all of the trusted
# root certificates from Windows Update, which is a lot of certificates.  This
# could potentially cause issues with some applications, so be sure to test this
# in a controlled environment before deploying it to all devices.

# Note: Windows Update will normally handle certificate updates itself, there shouldn't
# be a need to do it this way.  Even if your organization chooses to self manage certificates
# that should be done through a Domain Controller or GPO, this script should be a last
# resort for fixing a machine that for some reason has lost some or all of its trusted
# root certificates.

# Path to the .sst file
$curFolder = Get-Location
$sstFilePath = "$curFolder\Rootstore.sst"

# Pull all trusted root certs from WU - Note: This gets thick, approx 500 certs are pulled down
CertUtil -generateSSTFromWU $sstFilePath

# Load the .sst file as a certificate collection
$certCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$certCollection.Import($sstFilePath)

# Iterate through certificates and add them to the Trusted Root store
foreach ($cert in $certCollection) {
    Write-Host "Installing certificate: $($cert.Subject)" -ForegroundColor Green
    
	# Add to LocalMachine\Root (Trusted Root Certification Authorities)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $store.Open("ReadWrite")
    $store.Add($cert)
    $store.Close()
}
Write-Host "All certificates from the .sst file have been installed." -ForegroundColor Cyan