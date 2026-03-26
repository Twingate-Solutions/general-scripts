#Requires -Modules Pester

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'Deploy-TwingateConnector.ps1'
    $scriptContent = Get-Content $scriptPath -Raw

    # Strip param block and Main call so we can load functions only
    $functionsOnly = $scriptContent `
        -replace '(?s)\[CmdletBinding.*?^param\s*\(.*?\n\)', '' `
        -replace '(?m)^Main\s*$', ''
    Invoke-Expression $functionsOnly
}

Describe 'Write-Status' {
    It 'does not throw for Info type' {
        { Write-Status 'hello' -Type Info } | Should -Not -Throw
    }

    It 'does not throw for Warning type' {
        { Write-Status 'warn' -Type Warning } | Should -Not -Throw
    }

    It 'throws on invalid Type' {
        { Write-Status 'bad' -Type Invalid } | Should -Throw
    }
}

Describe 'New-CloudInitUserData' {
    It 'generates a username starting with tg' {
        $result = New-CloudInitUserData `
            -VmName 'TG-Connector-Test-1' `
            -SshPublicKey 'ssh-ed25519 AAAA testkey' `
            -AccessToken 'access-tok' `
            -RefreshToken 'refresh-tok' `
            -TwingateNetwork 'acme'

        $result.Username | Should -Match '^tg[a-z]{8}$'
    }

    It 'includes the SSH public key in user-data' {
        $result = New-CloudInitUserData `
            -VmName 'TG-Connector-Test-1' `
            -SshPublicKey 'ssh-ed25519 AAAA testkey comment' `
            -AccessToken 'at' -RefreshToken 'rt' -TwingateNetwork 'acme'

        $result.UserData | Should -Match 'ssh-ed25519 AAAA testkey comment'
    }

    It 'includes cloud-config header' {
        $result = New-CloudInitUserData `
            -VmName 'TG-Connector-Test-1' `
            -SshPublicKey 'key' -AccessToken 'at' -RefreshToken 'rt' -TwingateNetwork 'acme'

        $result.UserData | Should -Match '#cloud-config'
    }

    It 'embeds the access and refresh tokens in runcmd' {
        $result = New-CloudInitUserData `
            -VmName 'TG-Connector-Test-1' `
            -SshPublicKey 'key' -AccessToken 'myAccessToken' -RefreshToken 'myRefreshToken' `
            -TwingateNetwork 'acme'

        $result.UserData | Should -Match 'myAccessToken'
        $result.UserData | Should -Match 'myRefreshToken'
    }

    It 'lowercases and sanitizes the hostname' {
        $result = New-CloudInitUserData `
            -VmName 'TG-Connector-My Network-1' `
            -SshPublicKey 'key' -AccessToken 'at' -RefreshToken 'rt' -TwingateNetwork 'acme'

        $result.UserData | Should -Match 'hostname: tg-connector-my-network-1'
    }
}

Describe 'Remove-TwingateConnector' {
    It 'returns false and logs warning when API reports failure' {
        Mock Invoke-TwingateApi {
            return @{ connectorDelete = @{ ok = $false; error = 'Not found' } }
        }

        $secToken = ConvertTo-SecureString 'tok' -AsPlainText -Force
        $result = Remove-TwingateConnector -Network 'acme' -Token $secToken -ConnectorId 'abc123'
        $result | Should -Be $false
    }

    It 'returns true on success' {
        Mock Invoke-TwingateApi {
            return @{ connectorDelete = @{ ok = $true; error = $null } }
        }

        $secToken = ConvertTo-SecureString 'tok' -AsPlainText -Force
        $result = Remove-TwingateConnector -Network 'acme' -Token $secToken -ConnectorId 'abc123'
        $result | Should -Be $true
    }
}

Describe 'Get-TwingateRemoteNetwork' {
    It 'exits when remote network is not found' {
        Mock Invoke-TwingateApi {
            return @{ remoteNetwork = $null }
        }

        $secToken = ConvertTo-SecureString 'tok' -AsPlainText -Force
        { Get-TwingateRemoteNetwork -Network 'acme' -Token $secToken -Name 'Missing' } | Should -Throw
    }

    It 'returns the network ID when found' {
        Mock Invoke-TwingateApi {
            return @{ remoteNetwork = @{ id = 'abc'; name = 'Office'; isActive = $true } }
        }

        $secToken = ConvertTo-SecureString 'tok' -AsPlainText -Force
        $id = Get-TwingateRemoteNetwork -Network 'acme' -Token $secToken -Name 'Office'
        $id | Should -Be 'abc'
    }
}
