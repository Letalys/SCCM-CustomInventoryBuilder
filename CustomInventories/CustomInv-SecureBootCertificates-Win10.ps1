<#
.SYNOPSIS
  Getting Secureboot Certificate State
.DESCRIPTION
  This inventory help to manage the change of Secureboot Certificate
.OUTPUTS
   [key]
   Manufacturer 
   Model
   Version
   SN
   OperatingSystem
   BIOSManufacturer
   BIOSVersion
   isSecureBootActivated
   isSecureBootCertificateCompliant

.NOTES
  Version:        1.0
  Author:         Letalys
  Creation Date:  12/05/2026
  Purpose/Change: Initial script development
.LINK
    Author : Letalys (https://github.com/Letalys)
#>

$VerbosePreference = 'SilentlyContinue'

Function Invoke-CCMHardwareInventory{
    Begin{
      Write-Verbose "Trying to perform CCM hardware inventory..."
    }
    Process{
      Try{
        $GetSMSClient = Get-CimInstance -Class "SMS_Client" -Namespace 'root\ccm' -ErrorAction SilentlyContinue
        if($null -ne $GetSMSClient){
            Write-Verbose "CCM Agent found, performing hardware inventory."

	        $SMSClient = [wmiclass] "\\$($env:COMPUTERNAME)\root\ccm:SMS_Client"
	        $SMSClient.TriggerSchedule("{00000000-0000-0000-0000-000000000001}") | Out-Null
        }else{
            Write-Verbose "CCM Agent not found, will not perform hardware inventory."
        }
      }Catch{
        Write-Verbose "$($_.InvocationInfo.ScriptLineNumber) : $($_)"
        Break
      }
    }
    End{
      If($?){
        Write-Verbose "Completed Successfully."
      }
    }
}
Function New-WMIClass{
    [CmdletBinding()]
	param
	(
		[ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$ClassName,
		[ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][Object]$ClassTemplate
	)
    
    Begin{}
    Process{
        $CurrentWMI = Get-CimInstance $ClassName -ErrorAction SilentlyContinue

	    if ($null -ne $CurrentWMI) {
		    $CurrentWMI | Remove-CimInstance

		    $CurrentWMI = Get-CimInstance $ClassName -ErrorAction SilentlyContinue
		    if ($null -eq $CurrentWMI) {
			    $Output += "OK"
		    } else {
			    $Output += "WMI Instance always exist"
			    exit 1
		    }
		    Write-Verbose $Output
	    }

        Write-Verbose "Create New WMI Class :  $ClassName"

        $newClass = New-Object System.Management.ManagementClass("root\cimv2", [String]::Empty, $null);
	    $newClass["__CLASS"] = $ClassName;
        $newClass.Qualifiers.Add("Static", $true)

        $newClass.Properties.Add("Key", [System.Management.CimType]::String, $false)
        $newClass.Properties["Key"].Qualifiers.Add("Key", $true)

        $TemplateProperties = $ClassTemplate | Get-Member -MemberType NoteProperty

        foreach($prop in $TemplateProperties){
            Write-Verbose "`t Add Class Property : $($Prop.Name)"
            $newClass.Properties.Add("$($Prop.Name)", [System.Management.CimType]::String, $false)
        }
            
        $newClass.Put() | Out-Null
    }
    End{}
}
Function Add-WMIInstances {
    [CmdletBinding()]
	param
	(
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$ClassName,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][System.Collections.Arraylist]$ObjectArrayList
	)
    Begin{}
    Process{
        foreach($o in $ObjectArrayList){
            #Create GUID Key
            $GUID = [GUID]::NewGuid()

            if($null -ne $o.Key){$Key = $o.key}else{$Key = $GUID}

            $CurrentObjectPropertiesList = $o | Get-Member -MemberType NoteProperty

            $AddInstance = New-CimInstance -ClassName $ClassName -Key $key
            Write-Verbose "Create Instance with key : $key"

            foreach($prop in $CurrentObjectPropertiesList){
                    Set-CimInstance -CimInstance $AddInstance -Property @{$Prop.Name = "$($o.($Prop.Name))"}     
            }
        }
    }
    End{}
}
Function Test-WMIClass{
    [CmdletBinding()]
	param
	(
		[ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$ClassName
	)
    $ClassExist = Get-CimInstance -ClassName $ClassName
    if($null -ne $ClassExist){
        Write-Verbose "Return 0 for good execution"
        return 0
    }else{
        Write-Verbose "Return 1 when Class Not create properly"
        return 1
    }
}

#region Custom Class Definition
$CurrentClassName = "CustomInventory_SecureBootCertificate"

$TemplateObject = New-Object PSObject
$TemplateObject | Add-Member -MemberType NoteProperty -Name "Manufacturer" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "Model" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "Version" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "SN" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "OperatingSystem" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "BIOSManufacturer" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "BIOSVersion" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "isSecureBootActivated" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "isSecureBootCertificateCompliant" -Value $null
$TemplateObject | Add-Member -MemberType NoteProperty -Name "EvaluationDate" -Value $null
#endregion Custom Class Definition

Try{
    #Define the ArrayList for your Instances Objects
    [System.Collections.Arraylist]$InstancesObjectArray =@()

    #region Custom Code
        #Check if Secure boot is activated
        try{
            $isSBActivated=Confirm-SecureBootUEFI

            #Check if secureboot certificate is compliant
            $match = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'

            if ($match) {
                $isSBCertificateCompliant="Compliant"
            } else {
                $isSBCertificateCompliant="NonCompliant"
            }
        }catch{
            $isSBActivated ="Error Unknown"
            $isSBCertificateCompliant ="Error Unknown"
        }

        $MyObjectInstance = New-Object PSObject

        $MyObjectInstance | Add-Member -Name "Manufacturer" -membertype Noteproperty -Value (Get-CimInstance Win32_ComputerSystem).Manufacturer
        $MyObjectInstance | Add-Member -Name "Model" -membertype Noteproperty -Value (Get-CimInstance Win32_ComputerSystem).Model
        $MyObjectInstance | Add-Member -Name "Version" -membertype Noteproperty -Value (Get-CimInstance -ClassName Win32_ComputerSystemProduct).Version
        $MyObjectInstance | Add-Member -Name "SN" -membertype Noteproperty -Value (Get-CimInstance -ClassName Win32_ComputerSystemProduct).IdentifyingNumber
        $MyObjectInstance | Add-Member -Name "BIOSManufacturer" -membertype Noteproperty -Value (Get-CimInstance -ClassName Win32_BIOS).Manufacturer
        $MyObjectInstance | Add-Member -Name "BIOSVersion" -membertype Noteproperty -Value (Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion
        $MyObjectInstance | Add-Member -Name "isSecureBootActivated" -membertype Noteproperty -Value $isSBActivated
        $MyObjectInstance | Add-Member -Name "isSecureBootCertificateCompliant" -membertype Noteproperty -Value $isSBCertificateCompliant
        $MyObjectInstance | Add-Member -Name "EvaluationDate" -membertype Noteproperty -Value (Get-Date -Format "yyyy/MM/dd HH:mm:ss")
        
        #Add Your Object to The ArrayList
        $InstancesObjectArray.Add($MyObjectInstance) | Out-Null

    #endregion Custom Code

    #Convert all object in Array to WMI Instance
    New-WMIClass -ClassName $CurrentClassName -ClassTemplate $TemplateObject
    Add-WMIInstances -ClassName $CurrentClassName -ObjectArrayList $InstancesObjectArray
    
    #Invoke Hardware Inventory
    Invoke-CCMHardwareInventory

    #Test
    Return (Test-WMIClass -ClassName $CurrentClassName)
}catch{
    Write-Host "An error occurred : "
    Write-Host "$($_.InvocationInfo.ScriptLineNumber) : $($_)"

    Write-Verbose $_
    Write-Verbose "Return -1 for general error"
    return -1
}
