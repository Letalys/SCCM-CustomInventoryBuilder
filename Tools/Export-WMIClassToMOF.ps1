<#
.SYNOPSIS
    Export one or several WMI classes to a MOF file ready to be imported in MECM Hardware Inventory.

.DESCRIPTION
    This script extracts the schema of existing WMI classes (typically custom classes generated
    by the SCCM-CustomInventoryBuilder template) from a reference computer and produces a MOF
    file directly importable in the MECM console via :

        Administration > Client Settings > <Your Settings> > Hardware Inventory > Set Classes > Import

    Unlike a raw WMI MOF export, this script automatically injects all the SMS qualifiers
    required by MECM (SMS_Report, SMS_Group_Name, SMS_Class_ID, SMS_Class_Template inheritance)
    on both the class and its properties. By default, all properties are flagged for reporting
    (SMS_Report TRUE) - you can fine-tune the selection afterwards directly in the MECM console.

    This workflow is useful when the MECM console cannot reach the reference computer remotely
    (closed firewall flows, isolated networks, etc.). The MOF file can be transferred manually
    to the MECM server.

.PARAMETER ClassName
    One or several WMI class names to export (string array).

.PARAMETER Namespace
    Source WMI namespace where the classes are located on the reference computer.
    Default is "root\cimv2".

.PARAMETER OutputPath
    Full path of the resulting MOF file. The parent directory is created if missing.

.PARAMETER ClassVersion
    Version string used in the SMS_Class_ID qualifier (format: CUSTOM|ClassName|Version).
    Default is "1.0". Increment this if you change the class schema and need MECM to refresh it.

.PARAMETER Force
    Overwrite the output file if it already exists.

.EXAMPLE
    .\Export-WMIClassToMOF.ps1 -ClassName "CustomInventory_SecureBootCertificate" `
                               -OutputPath "C:\Temp\CustomInventory_SecureBootCertificate.mof"

.EXAMPLE
    .\Export-WMIClassToMOF.ps1 -ClassName "CustomInventory_LocalAdmin","CustomInventory_PnPDrivers" `
                               -OutputPath "C:\Temp\CustomInventories.mof" `
                               -ClassVersion "1.1" -Force -Verbose

.OUTPUTS
    A MECM-compatible MOF file at the specified OutputPath. Return codes :
        0  : Success
        1  : One or more classes not found in the given namespace
       -1  : General error

.NOTES
    Version:        1.0
    Author:         Letalys
    Creation Date:  2026-05-12
    Purpose/Change: Added full SMS qualifiers support for direct MECM console import.

    Companion tool of the SCCM-CustomInventoryBuilder repository.
    Run this script on the reference computer where the custom WMI classes have been created
    (typically after running the corresponding CustomInv-*.ps1 script at least once).

    Once imported in MECM, you can fine-tune which properties are actually reported by
    checking/unchecking them in the Hardware Inventory Classes window.

.LINK
    Author : Letalys (https://github.com/Letalys)
    Repo   : https://github.com/Letalys/SCCM-CustomInventoryBuilder
#>

[CmdletBinding()]
param
(
    [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string[]]$ClassName,
    [ValidateNotNullOrEmpty()][Parameter(Mandatory=$false)][string]$Namespace = "root\cimv2",
    [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateNotNullOrEmpty()][Parameter(Mandatory=$false)][string]$ClassVersion = "1.0",
    [Parameter(Mandatory=$false)][switch]$Force
)

$VerbosePreference = 'SilentlyContinue'

Function Test-WMIClassExists{
    [CmdletBinding()]
    param
    (
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$ClassName,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$Namespace
    )

    Begin{
        Write-Verbose "Checking existence of class '$ClassName' in namespace '$Namespace'..."
    }
    Process{
        Try{
            $Class = Get-CimClass -ClassName $ClassName -Namespace $Namespace -ErrorAction SilentlyContinue
            if($null -ne $Class){
                Write-Verbose "`tClass '$ClassName' found."
                return $true
            }else{
                Write-Verbose "`tClass '$ClassName' NOT found."
                return $false
            }
        }Catch{
            Write-Verbose "$($_.InvocationInfo.ScriptLineNumber) : $($_)"
            return $false
        }
    }
    End{}
}

Function Get-WMIClassProperties{
    [CmdletBinding()]
    param
    (
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$ClassName,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$Namespace
    )

    Begin{
        Write-Verbose "Retrieving properties of class '$ClassName'..."
    }
    Process{
        Try{
            $Class = Get-CimClass -ClassName $ClassName -Namespace $Namespace -ErrorAction Stop

            # Build an ordered list of properties with their CIM type and key flag.
            # We use the CIM type to map back to a MOF-compatible type string.
            [System.Collections.ArrayList]$PropertiesList = @()

            foreach($Prop in $Class.CimClassProperties){
                $IsKey = $false
                if($Prop.Qualifiers){
                    $KeyQualifier = $Prop.Qualifiers | Where-Object { $_.Name -eq "Key" }
                    if($null -ne $KeyQualifier){ $IsKey = $true }
                }

                $PropertyInfo = [PSCustomObject]@{
                    Name    = $Prop.Name
                    CimType = $Prop.CimType
                    IsKey   = $IsKey
                }
                [void]$PropertiesList.Add($PropertyInfo)
            }

            Write-Verbose "`tFound $($PropertiesList.Count) property(ies)."
            return ,$PropertiesList
        }Catch{
            Write-Verbose "$($_.InvocationInfo.ScriptLineNumber) : $($_)"
            return $null
        }
    }
    End{}
}

Function ConvertTo-MOFType{
    [CmdletBinding()]
    param
    (
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$CimType
    )

    # Map CIM types to MOF types. Most custom inventories use string only,
    # but we map the common ones for robustness.
    switch -Regex ($CimType){
        '^String'    { return "string" }
        '^Boolean'   { return "boolean" }
        '^DateTime'  { return "datetime" }
        '^UInt8'     { return "uint8" }
        '^UInt16'    { return "uint16" }
        '^UInt32'    { return "uint32" }
        '^UInt64'    { return "uint64" }
        '^SInt8'     { return "sint8" }
        '^SInt16'    { return "sint16" }
        '^SInt32'    { return "sint32" }
        '^SInt64'    { return "sint64" }
        '^Real32'    { return "real32" }
        '^Real64'    { return "real64" }
        '^Char16'    { return "char16" }
        default      { return "string" } # Safe fallback for MECM
    }
}

Function New-MECMClassDefinition{
    [CmdletBinding()]
    param
    (
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$ClassName,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][System.Collections.ArrayList]$Properties,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$ClassVersion
    )

    Begin{
        Write-Verbose "Generating MECM class definition for '$ClassName'..."
    }
    Process{
        Try{
            $Builder = New-Object System.Text.StringBuilder

            # Cleanup any previous version of the class (silently if not present)
            [void]$Builder.AppendLine("#pragma deleteclass(""$ClassName"", NOFAIL)")
            [void]$Builder.AppendLine("")

            # Class header with SMS qualifiers
            [void]$Builder.AppendLine("[ SMS_Report     (TRUE),")
            [void]$Builder.AppendLine("  SMS_Group_Name (""$ClassName""),")
            [void]$Builder.AppendLine("  SMS_Class_ID   (""CUSTOM|$ClassName|$ClassVersion"") ]")
            [void]$Builder.AppendLine("class $ClassName : SMS_Class_Template")
            [void]$Builder.AppendLine("{")

            # Properties
            foreach($Prop in $Properties){
                $MofType = ConvertTo-MOFType -CimType $Prop.CimType.ToString()

                if($Prop.IsKey){
                    [void]$Builder.AppendLine("    [SMS_Report (TRUE), key]")
                }else{
                    [void]$Builder.AppendLine("    [SMS_Report (TRUE)]")
                }
                [void]$Builder.AppendLine("    $MofType $($Prop.Name);")
                [void]$Builder.AppendLine("")
            }

            [void]$Builder.AppendLine("};")

            return $Builder.ToString()
        }Catch{
            Write-Verbose "$($_.InvocationInfo.ScriptLineNumber) : $($_)"
            return $null
        }
    }
    End{}
}

Function New-MOFFile{
    [CmdletBinding()]
    param
    (
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][System.Collections.ArrayList]$ClassDefinitions,
        [ValidateNotNullOrEmpty()][Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$false)][switch]$Force
    )

    Begin{
        Write-Verbose "Building MOF file '$OutputPath'..."
    }
    Process{
        Try{
            # Ensure parent directory exists
            $ParentDir = Split-Path -Path $OutputPath -Parent
            if(-not [string]::IsNullOrWhiteSpace($ParentDir) -and -not (Test-Path $ParentDir)){
                Write-Verbose "`tCreating parent directory '$ParentDir'."
                New-Item -Path $ParentDir -ItemType Directory -Force | Out-Null
            }

            # Handle overwrite
            if((Test-Path $OutputPath) -and -not $Force){
                Write-Verbose "`tFile already exists and -Force not specified. Aborting."
                Throw "Output file '$OutputPath' already exists. Use -Force to overwrite."
            }

            # Build MOF content
            $Builder = New-Object System.Text.StringBuilder
            [void]$Builder.AppendLine("//=====================================================================")
            [void]$Builder.AppendLine("// MOF file generated by Export-WMIClassToMOF.ps1")
            [void]$Builder.AppendLine("// Author          : Letalys (https://github.com/Letalys)")
            [void]$Builder.AppendLine("// Generated on    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
            [void]$Builder.AppendLine("// Source computer : $($env:COMPUTERNAME)")
            [void]$Builder.AppendLine("//=====================================================================")
            [void]$Builder.AppendLine("")
            [void]$Builder.AppendLine("#pragma namespace (""\\\\.\\root\\cimv2\\SMS"")")
            [void]$Builder.AppendLine("")

            foreach($Definition in $ClassDefinitions){
                [void]$Builder.AppendLine($Definition)
                [void]$Builder.AppendLine("")
            }

            # ASCII encoding is the safe choice for mofcomp and MECM console parser
            $Builder.ToString() | Out-File -FilePath $OutputPath -Encoding ASCII -Force

            Write-Verbose "`tMOF file successfully written to '$OutputPath'."
        }Catch{
            Write-Verbose "$($_.InvocationInfo.ScriptLineNumber) : $($_)"
            Throw
        }
    }
    End{}
}

Try{
    Write-Verbose "=== Export-WMIClassToMOF started ==="
    Write-Verbose "Namespace     : $Namespace"
    Write-Verbose "Classes       : $($ClassName -join ', ')"
    Write-Verbose "Class version : $ClassVersion"
    Write-Verbose "Output        : $OutputPath"

    #region Class existence check
    $MissingClasses = @()
    foreach($CurrentClass in $ClassName){
        if(-not (Test-WMIClassExists -ClassName $CurrentClass -Namespace $Namespace)){
            $MissingClasses += $CurrentClass
        }
    }

    if($MissingClasses.Count -gt 0){
        Write-Host "The following classes were not found in namespace '$Namespace' :" -ForegroundColor Red
        $MissingClasses | ForEach-Object { Write-Host "`t- $_" -ForegroundColor Red }
        Write-Verbose "Return 1 for missing classes."
        return 1
    }
    #endregion Class existence check

    #region Class definitions generation
    [System.Collections.ArrayList]$ClassDefinitions = @()

    foreach($CurrentClass in $ClassName){
        Write-Verbose "Processing class '$CurrentClass'..."

        $Properties = Get-WMIClassProperties -ClassName $CurrentClass -Namespace $Namespace
        if($null -eq $Properties -or $Properties.Count -eq 0){
            Write-Host "Failed to retrieve properties for class '$CurrentClass'." -ForegroundColor Red
            Write-Verbose "Return -1 for property retrieval failure."
            return -1
        }

        $Definition = New-MECMClassDefinition -ClassName $CurrentClass `
                                              -Properties $Properties `
                                              -ClassVersion $ClassVersion
        if($null -eq $Definition){
            Write-Host "Failed to generate MECM definition for class '$CurrentClass'." -ForegroundColor Red
            Write-Verbose "Return -1 for definition generation failure."
            return -1
        }

        [void]$ClassDefinitions.Add($Definition)
    }
    #endregion Class definitions generation

    #region MOF file generation
    New-MOFFile -ClassDefinitions $ClassDefinitions -OutputPath $OutputPath -Force:$Force
    #endregion MOF file generation

    Write-Host "MOF file successfully generated : $OutputPath" -ForegroundColor Green
    Write-Host "You can now import it in MECM via : Hardware Inventory > Set Classes > Import." -ForegroundColor Green

    Write-Verbose "Return 0 for good execution."
    return 0
}catch{
    Write-Host "An error occurred : " -ForegroundColor Red
    Write-Host "$($_.InvocationInfo.ScriptLineNumber) : $($_)" -ForegroundColor Red
    Write-Verbose $_
    Write-Verbose "Return -1 for general error."
    return -1
}