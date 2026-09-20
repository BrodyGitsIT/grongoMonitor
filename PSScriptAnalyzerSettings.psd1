@{
    # CI fails on Error severity only; Warnings are advisory.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The installer is an interactive console tool; Write-Host is intentional.
        'PSAvoidUsingWriteHost'

        # Process-DockerEvent / Write-EventLog predate the analyzer and are part of the
        # code base's vocabulary; renaming them buys nothing.
        'PSUseApprovedVerbs'

        # Internal helpers, not cmdlets meant for ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions'

        # Converting a plaintext token from a SecureString prompt is the whole point of
        # Read-ForwarderToken; the token file is what is protected.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingPlainTextForPassword'

        # Script-scoped runtime state is deliberate and documented at the top of the monitor.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
