<#
	PSScriptAnalyzer settings for the PowerShell the pipeline lints, from
	shcl's. Here rather than on the command line, so a run by hand gives the
	pipeline's answer.
#>
@{
	Severity = @('Error', 'Warning', 'Information')

	Rules = @{
		PSAvoidUsingDoubleQuotesForConstantString = @{
			Enable = $true
		}

		PSUseConsistentIndentation = @{
			Enable              = $true
			Kind                = 'tab'
			PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
		}
	}
}
