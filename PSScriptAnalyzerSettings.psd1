<#
	PSScriptAnalyzer settings for the PowerShell the pipeline lints, from
	shcl's. Here rather than on the command line, so a run by hand gives the
	pipeline's answer.
#>
@{
	Severity = @('Error', 'Warning')

	## Only Windows PowerShell 5.1 reads a file with no BOM as ANSI. These
	## scripts are Linux only, on pwsh 7, which reads UTF-8.
	ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')

	Rules = @{
		PSUseConsistentIndentation = @{
			Enable              = $true
			Kind                = 'tab'
			PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
		}
	}
}
