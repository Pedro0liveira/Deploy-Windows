function Invoke-Deployment {
    if ($script:State.rebootFrom) {
        if ($script:State.rebootFrom -eq (Get-BootMarker)) { Request-DeploymentReboot $script:State.stage; return }
        $script:State.rebootFrom = ''
        Save-DeploymentState
    }
    while ($true) {
        switch ($script:State.stage) {
            'Start' {
                Invoke-Checkpoint 'Identificação' "Nome calculado: $($script:DeployContext.TargetHostname); serial: $($script:DeployContext.Serial)."
                Invoke-NetworkStep
                Invoke-Checkpoint 'Rede' 'Rede e descoberta do domínio validadas.'
                Set-DeploymentState 'RenamePending'
            }
            'RenamePending' { Set-ComputerHostname; Request-DeploymentReboot 'AfterHostnameReboot'; return }
            'SoftwareRebootPending' { Set-DeploymentState 'AfterHostnameReboot' }
            'AfterHostnameReboot' {
                Assert-ComputerHostname
                Invoke-NetworkStep
                $needsReboot = Invoke-SoftwareStep
                if ($needsReboot) { Request-DeploymentReboot 'SoftwareRebootPending'; return }
                Invoke-PreDomainValidation
                Invoke-Checkpoint 'Pré-AD' 'Hostname, rede e aplicativos aprovados. A próxima etapa pede credenciais.'
                Set-DeploymentState 'JoinPending'
            }
            'JoinPending' { Invoke-PreDomainValidation; Join-ConfiguredDomain; Request-DeploymentReboot 'AfterDomainJoinReboot'; return }
            'AfterDomainJoinReboot' {
                Invoke-PostDomainValidation
                Invoke-Checkpoint 'AD' 'Domínio e canal seguro aprovados. OU final permanece manual.'
                Set-DeploymentState 'Completed'
            }
            'Completed' {
                Remove-DeploymentResume
                Write-DeployLog 'Orchestrator' 'Finish' SUCCESS 'Deploy concluído; conferir checklist de homologação e OU final.'
                Write-Host 'Deploy concluído. Confira o checklist final e mova a máquina para a OU correta.' -ForegroundColor Green
                return
            }
            default { throw "Estado desconhecido: $($script:State.stage)" }
        }
    }
}
