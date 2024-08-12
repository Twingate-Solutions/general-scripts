# Twingate Powershell Scripts

The scripts in this folder are meant to be used as the basis of scripts that can be used to automate various administrative tasks.

## Scripts

- **`twingate_client_installer.ps1`**: Powershell script to help automate deployment of the Twingate Client application to end user Windows devices, through a MDM such as Intune. The script has a number of optional features that it can be configured with, so it is important to review the script and adjust it to meet your specific requirements before deploying it in a production environment.
- **`twingate_client_uninstaller.ps1`**: Powershell script to help automate removal of the Twingate Client application from end user Windows devices, through a MDM such as Intune.
- **`unhinde_twingate_client_systray_icon_windows11.ps1`**: Powershell script to promote the Twingate client application's system tray icon to the taskbar in Windows 11. This script can be used to make the Twingate client application more visible to end users, and to make it easier for them to access the application's features.
- **`local-network-client-disabled.ps1`**: Powershell script to automate disbaling the Twingate Client application if it detects that the device is connected to a specific network. This script can be used to ensure that the Twingate Client is not used when the device is connected to a trusted network, but then restart the Client application once another network is detected.
