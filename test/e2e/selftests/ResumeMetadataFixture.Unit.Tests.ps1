#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

Describe 'Resume metadata fixtures' -Tag Unit {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\ItE2E\ItE2E.psd1') -Force
        $script:root = Join-Path $PSScriptRoot ("..\artifacts\resume-fixture-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root | Out-Null
        $script:sid = [guid]::NewGuid().ToString()
        $script:pane = [guid]::NewGuid().ToString()
        $script:gate = Join-Path $script:root 'release-hook'
        $script:hookLog = Join-Path $script:root 'hook.json'
        $script:launchLog = Join-Path $script:root 'launch.jsonl'
        $script:shim = Join-Path $script:root 'copilot.exe'
        $sink = Join-Path $script:root 'hook-sink.ps1'
        @'
$input | Set-Content -LiteralPath $env:ITE2E_HOOK_RECEIPT
exit 0
'@ | Set-Content -LiteralPath $sink
        $config = @{
            ITE2E_SHIM_PWSH = (Get-Command pwsh.exe).Source
            ITE2E_SHIM_FIXTURE = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Mock-InteractiveDelegate.ps1')).Path
            ITE2E_SHIM_LOG = $script:launchLog
            ITE2E_SHIM_RUN = $script:sid
            ITE2E_SHIM_WTCLI = $sink
            ITE2E_SHIM_RESUME_SESSION = $script:sid
            ITE2E_SHIM_SESSION_START_GATE = $script:gate
            ITE2E_SHIM_SESSION_START_TIMEOUT = '2'
        }
        $header = Join-Path $script:root 'config.h'
        @($config.Keys | ForEach-Object { "#define $_ LR`"ite2e($($config[$_]))ite2e`"" }) |
            Set-Content -LiteralPath $header -Encoding ascii
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $vs = Invoke-Native -FilePath $vswhere -Arguments @('-latest', '-products', '*',
            '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath') -TimeoutSec 10
        $vs.ExitCode | Should -Be 0
        $vcvars = Join-Path $vs.StdOut.Trim() 'VC\Auxiliary\Build\vcvars64.bat'
        $source = (Resolve-Path (Join-Path $PSScriptRoot '..\fixtures\Mock-CopilotDelegate.cpp')).Path
        $build = "call `"$vcvars`" >nul && cl /nologo /EHsc /std:c++17 /FI`"$header`" `"$source`" /Fe:`"$script:shim`" /Fo:`"$script:root\copilot.obj`" /link /INCREMENTAL:NO"
        $buildScript = "& `$env:ComSpec /d /c '$($build.Replace("'", "''"))'; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($buildScript))
        $compile = Invoke-Native -FilePath (Get-Command pwsh.exe).Source -Arguments @('-NoProfile', '-EncodedCommand', $encoded) `
            -WorkingDirectory $script:root -TimeoutSec 60
        $compile.ExitCode | Should -Be 0 -Because ($compile.StdOut + $compile.StdErr)
        $compile.TimedOut | Should -BeFalse

        function Start-ResumeFixtureProcess {
            param([string]$Executable, [string[]]$Arguments)
            $start = [Diagnostics.ProcessStartInfo]::new($Executable)
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardInput = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
            # Synthetic environment tests only the fixture, never a product session binding.
            $start.Environment['WT_SESSION'] = $script:pane
            $start.Environment.Remove('WT_COM_CLSID') | Out-Null
            $start.Environment['ITE2E_HOOK_RECEIPT'] = $script:hookLog
            $process = [Diagnostics.Process]::Start($start)
            [pscustomobject]@{
                Process = $process
                Output = $process.StandardOutput.ReadToEndAsync()
                Error = $process.StandardError.ReadToEndAsync()
            }
        }
        function Stop-ResumeFixtureProcess {
            param($Fixture)
            try {
                if (-not $Fixture.Process.HasExited) {
                    $Fixture.Process.StandardInput.Close()
                    if (-not $Fixture.Process.WaitForExit(5000)) {
                        $Fixture.Process.Kill($true)
                        throw 'Owned fixture exceeded its five-second EOF cleanup bound.'
                    }
                }
            }
            finally { $Fixture.Process.Dispose() }
        }
    }
    AfterAll {
        if ($script:root -and (Test-Path $script:root)) {
            Remove-Item -LiteralPath $script:root -Recurse -Force
        }
    }

    It 'optional ACP request capture preserves exact received content (<Capture>)' -ForEach @(
        @{ Capture = $true }, @{ Capture = $false }
    ) {
        $requestLog = Join-Path $script:root "requests-$Capture.jsonl"
        $arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot '..\fixtures\Mock-AcpChatAgent.ps1'),
            '-LogPath', (Join-Path $script:root "chat-$Capture.log"))
        if ($Capture) { $arguments += @('-RequestLogPath', $requestLog) }
        $fixture = Start-ResumeFixtureProcess -Executable (Get-Command pwsh.exe).Source -Arguments $arguments
        try {
            $marker = 'SCROLL_TURN_90_' + [guid]::NewGuid().ToString('N')
            $text = $marker + "`n" + '{"agent_session_id":"fixture-only-native-id"}'
            $request = @{ jsonrpc = '2.0'; id = 1; method = 'session/prompt'; params = @{
                sessionId = 'fixture-only-assistant'; prompt = @(@{ type = 'text'; text = $text })
            } }
            $fixture.Process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 10 -Compress))
            $fixture.Process.StandardInput.Close()
            $fixture.Process.WaitForExit(10000) | Should -BeTrue
            $fixture.Process.ExitCode | Should -Be 0 -Because $fixture.Error.GetAwaiter().GetResult()
            $fixture.Output.GetAwaiter().GetResult() | Should -Match ([regex]::Escape("ACK_$marker"))
            (Test-Path $requestLog) | Should -Be $Capture
            if ($Capture) {
                $received = Get-Content $requestLog -Raw | ConvertFrom-Json
                $received.session_id | Should -Be 'fixture-only-assistant'
                $received.text | Should -Be $text
                $received.prompt[0].text | Should -Be $text
            }
        }
        finally { Stop-ResumeFixtureProcess $fixture }
    }

    It 'native shim holds the hook until gate release and forwards the configured timeout' {
        $fixture = Start-ResumeFixtureProcess -Executable $script:shim -Arguments @('--resume', $script:sid)
        try {
            $waiting = "$script:gate.waiting-$script:sid.json"
            Wait-Until -TimeoutSec 5 -IntervalSec 0.05 -Condition { Test-Path $waiting } | Out-Null
            $receipt = Get-Content $waiting -Raw | ConvertFrom-Json
            $receipt.session_id | Should -Be $script:sid
            $receipt.pane_session_id | Should -Be $script:pane
            Test-Path $script:hookLog | Should -BeFalse
            Test-Path $script:launchLog | Should -BeFalse
            $fixture.Process.HasExited | Should -BeFalse
            Set-Content -LiteralPath $script:gate -Value 'release'
            $fixture.Process.StandardInput.WriteLine('exit')
            $fixture.Process.StandardInput.Flush()
            $fixture.Process.WaitForExit(10000) | Should -BeTrue
            $fixture.Process.ExitCode | Should -Be 0 -Because $fixture.Error.GetAwaiter().GetResult()
            (Get-Content $script:hookLog -Raw | ConvertFrom-Json).session_id | Should -Be $script:sid
            (Get-Content $script:launchLog -Raw | ConvertFrom-Json).command_line | Should -Match 'SessionStartTimeoutSec 2'
            Test-Path "$script:gate.emitted-$script:sid.json" | Should -BeTrue
        }
        finally { Stop-ResumeFixtureProcess $fixture }
    }

    It 'an unreleased native gate fails at its configured deadline without emitting a hook' {
        foreach ($path in @($script:gate, $script:hookLog, $script:launchLog,
                "$script:gate.waiting-$script:sid.json", "$script:gate.emitted-$script:sid.json")) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        $fixture = Start-ResumeFixtureProcess -Executable $script:shim -Arguments @('--resume', $script:sid)
        try {
            $fixture.Process.WaitForExit(10000) | Should -BeTrue
            $fixture.Process.ExitCode | Should -Not -Be 0
            $fixture.Error.GetAwaiter().GetResult() | Should -Match 'Session-start gate was not released'
            Test-Path $script:hookLog | Should -BeFalse
            Test-Path $script:launchLog | Should -BeFalse
        }
        finally { Stop-ResumeFixtureProcess $fixture }
    }
}
