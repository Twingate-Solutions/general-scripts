# Twingate Powershell Scripts

The scripts in this folder are meant to be used as the basis of scripts that can be used to automate various administrative tasks.

## Client deployment & lifecycle

- **`twingate_client_installer.ps1`**: Powershell script to help automate deployment of the Twingate Client application to end user Windows devices, through a MDM such as Intune. The script has a number of optional features that it can be configured with, so it is important to review the script and adjust it to meet your specific requirements before deploying it in a production environment.
- **`service-key-deployment.ps1`**: Powershell script to install a client in headless mode on a Windows system, using a service key. The service key needs to be generated in the admin console first and pasted in to the variable in the script, everything else should be automated. This script is useful for deploying the Twingate client on Windows systems that are not user-facing, such as servers or virtual machines.
- **`twingate_client_uninstaller.ps1`**: Powershell script to help automate removal of the Twingate Client application from end user Windows devices, through a MDM such as Intune.
- **`detect-installed-client-out-of-date.ps1`**: Powershell script to compare the installed version of the Twingate Client against the Twingate Client changelog RSS feed, and then exit code 1 or 0 depending on if it doesn't match or does.

## User experience / notifications

- **`user_not_logged_in_notification.ps1`**: Powershell script to automate sending a notification to a user when they are not logged in to the Twingate Client application. This script can be used to remind users to log in to the Twingate Client application, and to provide them with instructions on how to do so.
- **`unhide_twingate_client_systray_icon_windows11.ps1`**: Powershell script to promote the Twingate client application's system tray icon to the taskbar in Windows 11. This script can be used to make the Twingate client application more visible to end users, and to make it easier for them to access the application's features.
- **`local-network-client-disabled.ps1`**: Powershell script to automate disabling the Twingate Client application if it detects that the device is connected to a specific network. This script can be used to ensure that the Twingate Client is not used when the device is connected to a trusted network, but then restart the Client application once another network is detected.

## Diagnostics / fixes

- **`root-certs.ps1`**: Powershell script to automate the installation of the Windows Update based root certificates on a Windows device. This script is not specifically related to the Twingate service but more of a diagnostic and bandaid fix for Windows systems that have corrupted root certificate stores.

## Subprojects

- **`autopilot-scripting/`**: Ships headless Windows machines that auto-promote to the user-mode tray client on first logon. See its own README for full usage.
- **`hyperv-connector-deployment/`**: _Moved._ The Hyper-V connector deployment scripts now live in their own repository: [Twingate-Solutions/twingate-connector-hyperv](https://github.com/Twingate-Solutions/twingate-connector-hyperv).
