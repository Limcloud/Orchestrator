$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ================================================================
# Configuración de la demo
# ================================================================

$WorkingFolder  = "C:\Temp\SQLDemo"
$SqlZip         = Join-Path $WorkingFolder "SQLServer2025.zip"
$SsmsInstaller  = Join-Path $WorkingFolder "SSMS-Setup-ENU.exe"
$SqlMediaFolder = Join-Path $WorkingFolder "SQLMedia"

$LogFile        = Join-Path $WorkingFolder "Install-SQL2025.log"
$ResultFile     = Join-Path $WorkingFolder "Install-SQL2025.result"

$SaPassword     = "Vspotcr1!"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"

    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

function Test-SqlInstalled {
    return $null -ne (
        Get-Service `
            -Name "MSSQLSERVER" `
            -ErrorAction SilentlyContinue
    )
}

function Test-SsmsInstalled {
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $ssms = Get-ItemProperty `
        -Path $registryPaths `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DisplayName -like "*SQL Server Management Studio*"
    } |
    Select-Object -First 1

    return $null -ne $ssms
}

New-Item `
    -Path $WorkingFolder `
    -ItemType Directory `
    -Force |
Out-Null

Remove-Item `
    -Path $LogFile, $ResultFile `
    -Force `
    -ErrorAction SilentlyContinue

try {
    Write-Log "Starting SQL Server 2025 demo installation."
    Write-Log "Computer: $env:COMPUTERNAME"
    Write-Log "Execution user: $env:USERDOMAIN\$env:USERNAME"

    # ============================================================
    # Validar archivos locales
    # ============================================================

    if (-not (Test-Path $SqlZip)) {
        throw "SQLServer2025.zip was not found at $SqlZip"
    }

    if (-not (Test-Path $SsmsInstaller)) {
        throw "SSMS-Setup-ENU.exe was not found at $SsmsInstaller"
    }

    # ============================================================
    # Instalar SQL Server
    # ============================================================

    $sqlRebootRequired = $false

    if (-not (Test-SqlInstalled)) {
        Write-Log "Extracting SQL Server installation media."

        if (Test-Path $SqlMediaFolder) {
            Remove-Item `
                -Path $SqlMediaFolder `
                -Recurse `
                -Force
        }

        New-Item `
            -Path $SqlMediaFolder `
            -ItemType Directory `
            -Force |
        Out-Null

        Expand-Archive `
            -Path $SqlZip `
            -DestinationPath $SqlMediaFolder `
            -Force

        $setupFile = Get-ChildItem `
            -Path $SqlMediaFolder `
            -Filter "setup.exe" `
            -File `
            -Recurse |
        Select-Object -First 1

        if (-not $setupFile) {
            throw "setup.exe was not found after extracting SQLServer2025.zip."
        }

        Write-Log "SQL setup found at $($setupFile.FullName)"
        Write-Log "Installing SQL Server Database Engine."

        $sqlArguments = @(
            "/Q"
            "/ACTION=Install"
            "/FEATURES=SQLENGINE"
            "/INSTANCENAME=MSSQLSERVER"
            "/SQLSYSADMINACCOUNTS=BUILTIN\Administrators"
            "/SECURITYMODE=SQL"
            "/SAPWD=$SaPassword"
            "/TCPENABLED=1"
            "/NPENABLED=0"
            "/UPDATEENABLED=False"
            "/SQLSVCSTARTUPTYPE=Automatic"
            "/ENU"
            "/IACCEPTSQLSERVERLICENSETERMS"
        )

        $sqlProcess = Start-Process `
            -FilePath $setupFile.FullName `
            -ArgumentList $sqlArguments `
            -Wait `
            -PassThru

        Write-Log "SQL Server setup exit code: $($sqlProcess.ExitCode)"

        switch ($sqlProcess.ExitCode) {
            0 {
                Write-Log "SQL Server installed successfully."
            }

            3010 {
                $sqlRebootRequired = $true
                Write-Log "SQL Server installed successfully. Reboot required."
            }

            default {
                throw "SQL Server installation failed with exit code $($sqlProcess.ExitCode)."
            }
        }
    }
    else {
        Write-Log "SQL Server is already installed. Installation skipped."
    }

    # ============================================================
    # Validar servicio SQL
    # ============================================================

    Write-Log "Validating MSSQLSERVER service."

    $sqlService = Get-Service `
        -Name "MSSQLSERVER" `
        -ErrorAction Stop

    Set-Service `
        -Name "MSSQLSERVER" `
        -StartupType Automatic

    if ($sqlService.Status -ne "Running") {
        Start-Service -Name "MSSQLSERVER"

        $sqlService.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [TimeSpan]::FromMinutes(2)
        )
    }

    $sqlService = Get-Service -Name "MSSQLSERVER"

    if ($sqlService.Status -ne "Running") {
        throw "MSSQLSERVER service is not running."
    }

    Write-Log "MSSQLSERVER service is running."

    # ============================================================
    # Validar TCP 1433
    # ============================================================

    Write-Log "Validating TCP port 1433."

    $portListening = $false

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $sqlPort = Get-NetTCPConnection `
            -LocalPort 1433 `
            -State Listen `
            -ErrorAction SilentlyContinue

        if ($sqlPort) {
            $portListening = $true
            break
        }

        Start-Sleep -Seconds 5
    }

    if (-not $portListening) {
        throw "MSSQLSERVER is running, but TCP port 1433 is not listening."
    }

    Write-Log "SQL Server is listening on TCP 1433."

    # ============================================================
    # Instalar SSMS
    # ============================================================

    $ssmsRebootRequired = $false

    if (-not (Test-SsmsInstalled)) {
        Write-Log "Installing SQL Server Management Studio."

        $ssmsProcess = Start-Process `
            -FilePath $SsmsInstaller `
            -ArgumentList "/install /quiet /norestart" `
            -Wait `
            -PassThru

        Write-Log "SSMS setup exit code: $($ssmsProcess.ExitCode)"

        switch ($ssmsProcess.ExitCode) {
            0 {
                Write-Log "SSMS installed successfully."
            }

            3010 {
                $ssmsRebootRequired = $true
                Write-Log "SSMS installed successfully. Reboot required."
            }

            default {
                throw "SSMS installation failed with exit code $($ssmsProcess.ExitCode)."
            }
        }
    }
    else {
        Write-Log "SSMS is already installed. Installation skipped."
    }

    if (-not (Test-SsmsInstalled)) {
        throw "SSMS installation completed, but SSMS was not detected."
    }

    $rebootRequired =
        $sqlRebootRequired -or
        $ssmsRebootRequired

    Write-Log "SQL Server and SSMS installation completed successfully."

    @(
        "RESULT=SUCCESS"
        "COMPUTER=$env:COMPUTERNAME"
        "INSTANCE=MSSQLSERVER"
        "SERVICE_STATUS=Running"
        "TCP_PORT=1433"
        "SSMS_INSTALLED=True"
        "REBOOT_REQUIRED=$rebootRequired"
    ) | Set-Content `
        -Path $ResultFile `
        -Encoding UTF8

    exit 0
}
catch {
    $errorMessage = $_.Exception.Message

    Write-Log "Installation failed: $errorMessage"

    @(
        "RESULT=FAILED"
        "ERROR_TYPE=$($_.Exception.GetType().FullName)"
        "ERROR_MESSAGE=$errorMessage"
        "LOG_FILE=$LogFile"
    ) | Set-Content `
        -Path $ResultFile `
        -Encoding UTF8

    exit 1
}