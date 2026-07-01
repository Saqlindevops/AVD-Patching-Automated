param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$PipelineName = "AVD patching pipeline",

    [Parameter(Mandatory = $false)]
    [string]$RunUrl = ""
)

# ============================================================================
#  Best-effort email alert when an automated patch run fails.
#
#  IMPORTANT: This step needs an SMTP relay to actually send email. Set
#  "SmtpServer" (and optionally "NotifyFrom") in the config file. If SmtpServer
#  is left blank, this script does NOT fail - it just prints a reminder.
#
#  RECOMMENDED (no SMTP needed): also turn on Azure DevOps' built-in failure
#  notifications - see README-automation.md, "Failure alerts". That path emails
#  you automatically with zero infrastructure.
# ============================================================================

# Never let alerting itself fail the pipeline.
$ErrorActionPreference = "Continue"

try {
    $config = Get-Content $ConfigPath | ConvertFrom-Json
}
catch {
    Write-Host "Could not read config for notification. Skipping email. $($_.Exception.Message)"
    return
}

$notifyEmail = $config.NotifyEmail
$smtpServer  = $config.SmtpServer
$notifyFrom  = $config.NotifyFrom
if ([string]::IsNullOrWhiteSpace($notifyFrom)) {
    $notifyFrom = $notifyEmail
}

$subject = "[AVD Patching] Run FAILED - $PipelineName"
$body = @"
The automated AVD patching run has FAILED.

Pipeline : $PipelineName
Run link : $RunUrl

Please review the failed stage in Azure DevOps. The pipeline has already
attempted to clean up any temporary golden VM left behind by the failure.
"@

if ([string]::IsNullOrWhiteSpace($notifyEmail)) {
    Write-Host "NotifyEmail is not set in config. Skipping email alert."
    Write-Host "Tip: configure Azure DevOps built-in notifications (see README-automation.md)."
    return
}

if ([string]::IsNullOrWhiteSpace($smtpServer)) {
    Write-Host "SmtpServer is not set in config, so no email was sent from the pipeline."
    Write-Host "Recommended: use Azure DevOps built-in failure notifications (see README-automation.md)."
    Write-Host "Intended recipient: $notifyEmail"
    Write-Host "Subject: $subject"
    return
}

try {
    Write-Host "Sending failure email to $notifyEmail via $smtpServer ..."
    Send-MailMessage `
        -To $notifyEmail `
        -From $notifyFrom `
        -Subject $subject `
        -Body $body `
        -SmtpServer $smtpServer `
        -ErrorAction Stop
    Write-Host "Failure email sent."
}
catch {
    Write-Host "Could not send failure email: $($_.Exception.Message)"
    Write-Host "Fall back to Azure DevOps built-in notifications (see README-automation.md)."
}
