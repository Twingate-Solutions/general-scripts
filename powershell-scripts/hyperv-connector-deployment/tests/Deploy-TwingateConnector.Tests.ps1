#Requires -Modules Pester

# Pester 5+ runs It blocks in a separate scope from top-level code, so the
# script under test must be loaded inside BeforeAll (dot-sourced as a
# scriptblock) for its functions to be visible to the tests. We load only the
# Helper Functions region, which excludes the param block, Set-StrictMode, the
# Action Handlers, and Main (none of which are unit-tested directly).
BeforeAll {
    $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'Deploy-TwingateConnector.ps1'
    $scriptContent = Get-Content $scriptPath -Raw
    $functionsOnly = $scriptContent `
        -replace '(?s)^.*?#region Helper Functions\s*\n', '' `
        -replace '(?s)#endregion.*$', ''
    . ([ScriptBlock]::Create($functionsOnly))
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

        $result.Username | Should -Match '^tgadm[a-z0-9]{4}$'
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

    It 'writes the bootstrap script via write_files and executes it from runcmd' {
        $result = New-CloudInitUserData `
            -VmName 'TG-Connector-Test-1' `
            -SshPublicKey 'key' -AccessToken 'myAccessToken' -RefreshToken 'myRefreshToken' `
            -TwingateNetwork 'acme'

        # tokens still present (now inside the written bootstrap file content)
        $result.UserData | Should -Match 'myAccessToken'
        $result.UserData | Should -Match 'myRefreshToken'
        # bootstrap is written and run, not an inline curl|bash
        $result.UserData | Should -Match '/var/lib/twingate-bootstrap.sh'
        $result.UserData | Should -Match 'TG_MAX_ATTEMPTS='
        $result.UserData | Should -Not -Match "curl -s 'https://binaries.twingate.com/connector/setup.sh' \| sudo"
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

Describe 'Get-ConnectorBootstrapScript' {
    BeforeAll {
        $script:bs = Get-ConnectorBootstrapScript -AccessToken 'AT123' -RefreshToken 'RT456' -TwingateNetwork 'acme'
    }
    It 'embeds the access and refresh tokens and network' {
        $script:bs | Should -Match 'AT123'
        $script:bs | Should -Match 'RT456'
        $script:bs | Should -Match "TG_NETWORK='acme'"
    }
    It 'contains a bounded retry loop with a max-attempts ceiling' {
        $script:bs | Should -Match 'TG_MAX_ATTEMPTS=5'
        $script:bs | Should -Match 'while \[ "\$attempt" -le "\$TG_MAX_ATTEMPTS" \]'
        $script:bs | Should -Match 'giving up'
    }
    It 'uses dpkg as the install-success check' {
        $script:bs | Should -Match 'dpkg -s twingate-connector'
    }
    It 'enables, starts, labels, and restarts the connector on success' {
        $script:bs | Should -Match 'systemctl enable twingate-connector'
        $script:bs | Should -Match 'systemctl start twingate-connector'
        $script:bs | Should -Match 'TWINGATE_LABEL_DEPLOYED_BY='
        $script:bs | Should -Match 'systemctl restart twingate-connector'
    }
    It 'honors a custom MaxAttempts' {
        (Get-ConnectorBootstrapScript -AccessToken 'a' -RefreshToken 'r' -TwingateNetwork 'n' -MaxAttempts 3) |
            Should -Match 'TG_MAX_ATTEMPTS=3'
    }
    It 'is LF-normalized (no CR)' {
        $script:bs | Should -Not -Match "`r"
    }
}

Describe 'Resolve-QemuImgAssetUrl' {
    It 'returns the versioned zip asset URL from the latest release' {
        Mock Invoke-RestMethod {
            return [PSCustomObject]@{
                tag_name = 'v10.0.0'
                assets   = @(
                    [PSCustomObject]@{ name = 'source.zip'; browser_download_url = 'https://example/source.zip' },
                    [PSCustomObject]@{ name = 'qemu-img-windows-x64-v10.0.0.zip'; browser_download_url = 'https://example/qemu.zip' }
                )
            }
        }
        Resolve-QemuImgAssetUrl | Should -Be 'https://example/qemu.zip'
    }
    It 'returns null when the API call throws' {
        Mock Invoke-RestMethod { throw 'network down' }
        Resolve-QemuImgAssetUrl | Should -BeNullOrEmpty
    }
    It 'returns null when no matching asset is present' {
        Mock Invoke-RestMethod { return [PSCustomObject]@{ assets = @([PSCustomObject]@{ name = 'readme.txt'; browser_download_url = 'x' }) } }
        Resolve-QemuImgAssetUrl | Should -BeNullOrEmpty
    }
}

Describe 'Bootstrap retry harness' {
    It 'passes all retry scenarios under bash' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash not available'; return }

        $bs = Get-ConnectorBootstrapScript -AccessToken a -RefreshToken r -TwingateNetwork n
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "bs-$(Get-Random).sh"
        [System.IO.File]::WriteAllText($tmp, $bs, [System.Text.UTF8Encoding]::new($false))
        try {
            $harness = Join-Path $PSScriptRoot 'test-bootstrap-retry.sh'
            & $bash.Source $harness $tmp 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-SingleConnectorVM' {
    It 'rejects names outside the TG-Connector- convention without calling Get-VM' {
        Mock Get-VM { throw 'should not be called' }
        Resolve-SingleConnectorVM -VMName 'random-vm' -VMPath 'C:\X' | Should -BeNullOrEmpty
    }
    It 'returns VM, ConnectorId and SshUser parsed from Notes' {
        Mock Get-VM {
            return [PSCustomObject]@{ Name = 'TG-Connector-NY-1'; Notes = 'TwingateConnectorId=abc123;SshUser=tgadmwxyz' }
        }
        $r = Resolve-SingleConnectorVM -VMName 'TG-Connector-NY-1' -VMPath 'C:\X'
        $r.ConnectorId | Should -Be 'abc123'
        $r.SshUser     | Should -Be 'tgadmwxyz'
    }
    It 'returns null when the VM is not found' {
        Mock Get-VM { return $null }
        Resolve-SingleConnectorVM -VMName 'TG-Connector-NY-9' -VMPath 'C:\X' | Should -BeNullOrEmpty
    }
}

Describe 'Get-FixVMPlan' {
    It 'does nothing when the connector is already ALIVE' {
        Get-FixVMPlan -IsAlive $true -PackageInstalled $true | Should -Be 'none'
    }
    It 'starts the service when the package is installed but not ALIVE' {
        Get-FixVMPlan -IsAlive $false -PackageInstalled $true | Should -Be 'start'
    }
    It 'reprovisions when the package is missing and not ALIVE' {
        Get-FixVMPlan -IsAlive $false -PackageInstalled $false | Should -Be 'reprovision'
    }
}

Describe 'Get-SshErrorHint' {
    It 'maps the apt repo-missing signature to a FixVM hint' {
        $real = 'Reading package lists... E: Unable to locate package twingate-connector'
        (Get-SshErrorHint -Output $real) | Should -Match 'FixVM'
        (Get-SshErrorHint -Output $real) | Should -Match 'repo'
    }
    It 'maps DNS failures to a network hint' {
        (Get-SshErrorHint -Output 'Temporary failure in name resolution') | Should -Match 'DNS'
    }
    It 'returns null for unrecognized output' {
        Get-SshErrorHint -Output 'some unrelated text' | Should -BeNullOrEmpty
    }
}
