param(
    [Parameter(Mandatory = $true)] [string] $BackupManifestPath,
    [Parameter(Mandatory = $true)] [string] $SanitizerAuditPath,
    [Parameter(Mandatory = $true)] [string] $RestoreEvidencePath,
    [Parameter(Mandatory = $true)] [string] $OutputPath,
    [string] $ApprovalToken,
    [switch] $LocalTestMode,
    [Nullable[bool]] $LocalTestActiveAdministrator
)

$ErrorActionPreference = 'Stop'
$requiredCounts = @('import_files', 'payment_outbound', 'payment_mail_log', 'sharepoint_file_queue')
$requiredViews = @('vw_import_report', 'v_tbpayin_from_payment_outbound')
$utf8Strict = New-Object Text.UTF8Encoding($false, $true)
. (Join-Path $PSScriptRoot 'restore_acl_policy.ps1')

if (-not ('D365.RestoreStrictJsonV2' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
namespace D365 {
public static class RestoreStrictJsonV2 {
  static string s; static int i;
  public static void Validate(string text) { s=text; i=0; Value(); Ws(); if(i!=s.Length) Fail("trailing content"); }
  static void Ws(){while(i<s.Length && char.IsWhiteSpace(s[i]))i++;}
  static void Value(){Ws();if(i>=s.Length)Fail("unexpected end");char c=s[i];if(c=='{'){Obj();return;}if(c=='['){Arr();return;}if(c=='"'){Str();return;}if(Take("true")||Take("false")||Take("null"))return;Num();}
  static void Obj(){i++;Ws();var keys=new HashSet<string>(StringComparer.Ordinal);if(Peek('}')){i++;return;}while(true){string k=Str();if(!keys.Add(k))Fail("duplicate object key: "+k);Ws();Want(':');Value();Ws();if(Peek('}')){i++;return;}Want(',');}}
  static void Arr(){i++;Ws();if(Peek(']')){i++;return;}while(true){Value();Ws();if(Peek(']')){i++;return;}Want(',');}}
  static string Str(){Ws();Want('"');var b=new StringBuilder();while(i<s.Length){char c=s[i++];if(c=='"')return b.ToString();if(c<32)Fail("control character");if(c!='\\'){b.Append(c);continue;}if(i>=s.Length)Fail("incomplete escape");char e=s[i++];switch(e){case '"':case '\\':case '/':b.Append(e);break;case 'b':b.Append('\b');break;case 'f':b.Append('\f');break;case 'n':b.Append('\n');break;case 'r':b.Append('\r');break;case 't':b.Append('\t');break;case 'u':if(i+4>s.Length)Fail("unicode escape");int n;if(!int.TryParse(s.Substring(i,4),NumberStyles.HexNumber,CultureInfo.InvariantCulture,out n))Fail("unicode escape");b.Append((char)n);i+=4;break;default:Fail("escape");break;}}Fail("unterminated string");return null;}
  static void Num(){int start=i;if(Peek('-'))i++;if(i>=s.Length)Fail("number");if(Peek('0'))i++;else{if(!Digit19())Fail("number");while(i<s.Length&&char.IsDigit(s[i]))i++;}if(Peek('.')){i++;if(i>=s.Length||!char.IsDigit(s[i]))Fail("number");while(i<s.Length&&char.IsDigit(s[i]))i++;}if(Peek('e')||Peek('E')){i++;if(Peek('+')||Peek('-'))i++;if(i>=s.Length||!char.IsDigit(s[i]))Fail("number");while(i<s.Length&&char.IsDigit(s[i]))i++;}if(i==start)Fail("value");}
  static bool Digit19(){return i<s.Length&&s[i]>='1'&&s[i]<='9';}static bool Take(string x){if(i+x.Length<=s.Length&&string.CompareOrdinal(s,i,x,0,x.Length)==0){i+=x.Length;return true;}return false;}static bool Peek(char c){return i<s.Length&&s[i]==c;}static void Want(char c){Ws();if(!Peek(c))Fail("expected "+c);i++;}static void Fail(string m){throw new FormatException("Strict JSON "+m+" at "+i);}
}}
'@
}

function Get-Sha256([byte[]] $Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Get-FullPath([string] $Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\') }
function Assert-InsideRoot([string] $Path, [string] $Root, [switch] $AllowMissingLeaf) {
    $full = Get-FullPath $Path; $rootFull = Get-FullPath $Root
    if ($full -ine $rootFull -and -not $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Artifact path is outside the trusted backup root: $full" }
    if (@($full.Split([char]92) | Where-Object { $_ -match '~[0-9]+' }).Count -gt 0) { throw "Artifact path aliases are not allowed: $full" }
    $current = if ($AllowMissingLeaf -and -not (Test-Path -LiteralPath $full)) { Split-Path -Parent $full } else { $full }
    while ($current -and $current.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Artifact path contains a reparse component: $current" }
        }
        if ($current -ieq $rootFull) { break }
        $parent = Split-Path -Parent $current; if ($parent -eq $current) { break }; $current = $parent
    }
    return $full
}
function Assert-ProtectedAcl([string] $Path, [string[]] $AllowedWriterSids) {
    $helper = Join-Path $PSScriptRoot 'get_file_acl_evidence.ps1'
    $powerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $output = & $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Path $Path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($output -join "`n"))) { throw 'ACL evidence helper failed closed.' }
    $evidence = ConvertFrom-StrictJsonText ($output -join "`n") 'ACL evidence'
    Assert-RestoreAclEvidence -Evidence $evidence -AllowedWriterSids $AllowedWriterSids
}

function Skip-JsonWhitespace { while ($script:jsonIndex -lt $script:jsonText.Length -and [char]::IsWhiteSpace($script:jsonText[$script:jsonIndex])) { $script:jsonIndex++ } }
function Read-JsonStringToken {
    Skip-JsonWhitespace; if ($script:jsonIndex -ge $script:jsonText.Length -or $script:jsonText[$script:jsonIndex] -ne '"') { throw 'Strict JSON expected a string.' }
    $start = $script:jsonIndex++
    while ($script:jsonIndex -lt $script:jsonText.Length) {
        $c = $script:jsonText[$script:jsonIndex++]
        if ($c -eq '"') { return ($script:jsonText.Substring($start, $script:jsonIndex - $start) | ConvertFrom-Json) }
        if ([int][char]$c -lt 0x20) { throw 'Strict JSON contains a control character.' }
        if ($c -eq '\') {
            if ($script:jsonIndex -ge $script:jsonText.Length) { throw 'Strict JSON has an incomplete escape.' }
            $escape = $script:jsonText[$script:jsonIndex++]; if ('"\/bfnrtu'.IndexOf($escape) -lt 0) { throw 'Strict JSON has an invalid escape.' }
            if ($escape -eq 'u') { if ($script:jsonIndex + 4 -gt $script:jsonText.Length -or $script:jsonText.Substring($script:jsonIndex,4) -notmatch '^[0-9a-fA-F]{4}$') { throw 'Strict JSON has an invalid Unicode escape.' }; $script:jsonIndex += 4 }
        }
    }
    throw 'Strict JSON has an unterminated string.'
}
function Read-JsonValue {
    Skip-JsonWhitespace; if ($script:jsonIndex -ge $script:jsonText.Length) { throw 'Strict JSON ended unexpectedly.' }; $c = $script:jsonText[$script:jsonIndex]
    if ($c -eq '{') {
        $script:jsonIndex++; $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal); Skip-JsonWhitespace
        if ($script:jsonIndex -lt $script:jsonText.Length -and $script:jsonText[$script:jsonIndex] -eq '}') { $script:jsonIndex++; return }
        while ($true) { $key = Read-JsonStringToken; if (-not $keys.Add($key)) { throw "Strict JSON contains duplicate object key: $key" }; Skip-JsonWhitespace; if ($script:jsonIndex -ge $script:jsonText.Length -or $script:jsonText[$script:jsonIndex++] -ne ':') { throw 'Strict JSON expected a colon.' }; Read-JsonValue; Skip-JsonWhitespace; if ($script:jsonIndex -ge $script:jsonText.Length) { throw 'Strict JSON object ended unexpectedly.' }; $separator=$script:jsonText[$script:jsonIndex++]; if ($separator -eq '}') { return }; if ($separator -ne ',') { throw 'Strict JSON expected a comma.' } }
    }
    if ($c -eq '[') { $script:jsonIndex++; Skip-JsonWhitespace; if ($script:jsonIndex -lt $script:jsonText.Length -and $script:jsonText[$script:jsonIndex] -eq ']') { $script:jsonIndex++; return }; while ($true) { Read-JsonValue; Skip-JsonWhitespace; if ($script:jsonIndex -ge $script:jsonText.Length) { throw 'Strict JSON array ended unexpectedly.' }; $separator=$script:jsonText[$script:jsonIndex++]; if ($separator -eq ']') { return }; if ($separator -ne ',') { throw 'Strict JSON expected a comma.' } } }
    if ($c -eq '"') { [void](Read-JsonStringToken); return }
    $remaining = $script:jsonText.Substring($script:jsonIndex); $match=[regex]::Match($remaining,'^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)')
    if (-not $match.Success) { throw 'Strict JSON contains an invalid value.' }; $script:jsonIndex += $match.Length
}
function Read-StrictJsonSnapshot([string] $Path, [string] $Label) {
    try { $bytes=[IO.File]::ReadAllBytes($Path); $text=$utf8Strict.GetString($bytes) } catch { throw "$Label cannot be read as strict UTF-8 JSON." }
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text=$text.Substring(1) }
    $value=ConvertFrom-StrictJsonText $text $Label
    [pscustomobject]@{ Path=$Path; Bytes=$bytes; Text=$text; Value=$value; Hash=(Get-Sha256 $bytes); Size=[int64]$bytes.Length }
}
function ConvertFrom-StrictJsonText([string]$Text,[string]$Label) { try { [D365.RestoreStrictJsonV2]::Validate($Text) } catch { throw "$Label failed strict JSON validation: $($_.Exception.Message)" };try{$value=$Text|ConvertFrom-Json}catch{throw "$Label is not valid JSON."};if($null-eq$value){throw "$Label is not a JSON object."};$value }
function Read-ArtifactSnapshot([string] $Path, [string] $Label) { try { $bytes=[IO.File]::ReadAllBytes($Path) } catch { throw "$Label cannot be read." }; [pscustomobject]@{Path=$Path;Bytes=$bytes;Hash=(Get-Sha256 $bytes);Size=[int64]$bytes.Length} }
function Need($Object,[string]$Name,[string]$Label) { $p=$Object.PSObject.Properties[$Name]; if($null-eq$p-or$null-eq$p.Value){throw "$Label is missing $Name."};$p.Value }
function Assert-Integer($Value,[string]$Label) { $integral=$Value-is[byte]-or$Value-is[sbyte]-or$Value-is[int16]-or$Value-is[uint16]-or$Value-is[int]-or$Value-is[uint32]-or$Value-is[int64]-or$Value-is[uint64]; if(-not$integral-or[decimal]$Value-lt0){throw "$Label must be a native nonnegative integer."} }
function Assert-ExactKeys($Object,[string[]]$Expected,[string]$Label) { $actual=@($Object.PSObject.Properties.Name|Sort-Object);$wanted=@($Expected|Sort-Object);if(($actual-join "`n")-cne($wanted-join "`n")){throw "$Label has missing or extra keys."} }

$approverSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($approverSid -notmatch '^S-1-(?:[0-9]+-)+[0-9]+$') { throw 'Current approver SID could not be determined.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($PSBoundParameters.ContainsKey('LocalTestActiveAdministrator') -and -not $LocalTestMode) { throw 'LocalTestActiveAdministrator is forbidden outside LocalTestMode.' }
if ($LocalTestMode -and $PSBoundParameters.ContainsKey('LocalTestActiveAdministrator')) { $activeAdministrator=[bool]$LocalTestActiveAdministrator }
else { $principal=New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity; $activeAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
Assert-RestoreApproverToken -UserSid $approverSid -ActiveAdministrator $activeAdministrator
$allowedWriterSids = @('S-1-5-18','S-1-5-32-544')
$manifestFull=Get-FullPath $BackupManifestPath
if ($LocalTestMode) { $temp=Get-FullPath ([IO.Path]::GetTempPath()); $trustedRoot=Get-FullPath (Split-Path -Parent $manifestFull); if ($trustedRoot -ieq $temp -or -not $trustedRoot.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'LocalTestMode artifacts must use a dedicated directory under system temp.' } }
else { $candidates=@('C:\xampp\backups\d365\uat','C:\xampp\backups\d365\prod','\\100.1.1.166\c$\xampp\backups\d365\uat','\\100.1.1.166\c$\xampp\backups\d365\prod');$trustedRoot=$null;foreach($candidate in $candidates){$root=Get-FullPath $candidate;if($manifestFull.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){$trustedRoot=$root;break}};if(-not$trustedRoot){throw 'Backup manifest is outside approved D365 backup roots.'} }
$manifestFull=Assert-InsideRoot $manifestFull $trustedRoot; $auditFull=Assert-InsideRoot $SanitizerAuditPath $trustedRoot; $evidenceFull=Assert-InsideRoot $RestoreEvidencePath $trustedRoot; $outputFull=Assert-InsideRoot $OutputPath $trustedRoot -AllowMissingLeaf
if (-not $LocalTestMode) { foreach ($protectedPath in @($trustedRoot,$manifestFull,$auditFull,$evidenceFull,(Split-Path -Parent $outputFull))) { Assert-ProtectedAcl $protectedPath $allowedWriterSids } }
$manifest=Read-StrictJsonSnapshot $manifestFull 'Backup manifest';$m=$manifest.Value;$release=[string](Need $m release_id 'Backup manifest');$database=[string](Need $m database 'Backup manifest')
$expectedSegment=if($database-ceq'D365_finance'){'uat'}elseif($database-ceq'D365_finance_prod'){'prod'}else{throw 'Backup manifest database is not approved.'};if(-not$LocalTestMode-and(Split-Path -Leaf $trustedRoot)-cne$expectedSegment){throw 'Backup manifest database does not match trusted environment segment.'}
$backupPath=Assert-InsideRoot ([string](Need $m backup_file 'Backup manifest')) $trustedRoot;$backup=Read-ArtifactSnapshot $backupPath 'Backup';Assert-Integer (Need $m size_bytes 'Backup manifest') 'Backup manifest size';if($backup.Hash-cne([string](Need $m sha256 'Backup manifest')).ToLowerInvariant()-or$backup.Size-ne[long]$m.size_bytes){throw 'Backup does not match manifest hash or size.'}
$audit=Read-StrictJsonSnapshot $auditFull 'Sanitizer audit';$a=$audit.Value;$auditSource=Assert-InsideRoot ([string](Need $a source_path 'Sanitizer audit')) $trustedRoot;if($auditSource-ine$backup.Path){throw 'Sanitizer audit source path does not match backup.'};$auditRehearsal=[string](Need $a rehearsal_database 'Sanitizer audit');$rehearsalPrefix=$database+'_rehearsal_';if($auditRehearsal-notmatch'^[A-Za-z0-9_]+$'-or-not$auditRehearsal.StartsWith($rehearsalPrefix,[StringComparison]::OrdinalIgnoreCase)-or$auditRehearsal.Length-le$rehearsalPrefix.Length){throw 'Sanitizer audit rehearsal database is unsafe or cross-environment.'};$sanitizedPath=Assert-InsideRoot ([string](Need $a sanitized_path 'Sanitizer audit')) $trustedRoot;$sanitized=Read-ArtifactSnapshot $sanitizedPath 'Sanitized backup';Assert-Integer (Need $a sanitized_size_bytes 'Sanitizer audit') 'Sanitized size';if(([string](Need $a source_database 'Sanitizer audit'))-cne$database-or([string](Need $a source_sha256 'Sanitizer audit')).ToLowerInvariant()-cne$backup.Hash-or$sanitized.Hash-cne([string](Need $a sanitized_sha256 'Sanitizer audit')).ToLowerInvariant()-or$sanitized.Size-ne[long]$a.sanitized_size_bytes){throw 'Sanitizer audit does not bind verified artifacts.'}
if (-not $LocalTestMode) { Assert-ProtectedAcl $backup.Path $allowedWriterSids; Assert-ProtectedAcl $sanitized.Path $allowedWriterSids }
$evidence=Read-StrictJsonSnapshot $evidenceFull 'Restore evidence';$e=$evidence.Value;if(([string](Need $e status 'Restore evidence'))-cne'VERIFIED'-or([string](Need $e release_id 'Restore evidence'))-cne$release-or([string](Need $e database 'Restore evidence'))-cne$database-or([string](Need $e backup_sha256 'Restore evidence')).ToLowerInvariant()-cne$backup.Hash-or([string](Need $e sanitized_sha256 'Restore evidence')).ToLowerInvariant()-cne$sanitized.Hash){throw 'Restore evidence does not bind verified artifacts.'}
$rehearsal=[string](Need $e rehearsal_database 'Restore evidence');if($rehearsal-notmatch'^[A-Za-z0-9_]+$'-or-not$rehearsal.StartsWith($database+'_rehearsal_',[StringComparison]::OrdinalIgnoreCase)-or$rehearsal-cne$auditRehearsal){throw 'Rehearsal database is unsafe, cross-environment, or mismatched.'};$counts=Need $e row_counts 'Restore evidence';Assert-ExactKeys $counts $requiredCounts 'row_counts';foreach($name in $requiredCounts){Assert-Integer(Need $counts $name row_counts)"row_counts.$name"};$views=Need $e views 'Restore evidence';Assert-ExactKeys $views $requiredViews 'views';foreach($name in $requiredViews){$view=Need $views $name views;Assert-ExactKeys $view @('row_count','security_type')"views.$name";Assert-Integer(Need $view row_count "views.$name")"views.$name.row_count";if(([string](Need $view security_type "views.$name"))-cne'INVOKER'){throw "View $name must use INVOKER."}}
Assert-Integer(Need $e live_schema_reference_count 'Restore evidence')'live_schema_reference_count';if($e.live_schema_reference_count-ne0-or[string]::IsNullOrWhiteSpace([string](Need $e verified_at 'Restore evidence'))-or[string]::IsNullOrWhiteSpace([string](Need $e verified_by 'Restore evidence'))){throw 'Restore evidence verification metadata is invalid.'}
$expected="RESTORE TEST PASSED $release";if([string]::IsNullOrWhiteSpace($ApprovalToken)){$ApprovalToken=Read-Host "Type $expected only after successful restore verification"};if($ApprovalToken-cne$expected){throw 'Restore rehearsal approval token did not match.'}
Assert-InsideRoot $outputFull $trustedRoot -AllowMissingLeaf|Out-Null
$receipt=[ordered]@{status='PASSED';release_id=$release;database=$database;rehearsal_database=$rehearsal;backup_path=$backup.Path;backup_sha256=$backup.Hash;backup_size_bytes=$backup.Size;sanitizer_audit_path=$audit.Path;sanitizer_audit_sha256=$audit.Hash;sanitizer_audit_size_bytes=$audit.Size;sanitized_path=$sanitized.Path;sanitized_sha256=$sanitized.Hash;sanitized_size_bytes=$sanitized.Size;evidence_path=$evidence.Path;evidence_sha256=$evidence.Hash;evidence_size_bytes=$evidence.Size;row_counts=$counts;views=$views;live_schema_reference_count=0;approved_at=(Get-Date).ToUniversalTime().ToString('o');approved_by=[Environment]::UserName;approved_by_sid=$approverSid}
$receiptBytes=$utf8Strict.GetBytes(($receipt|ConvertTo-Json -Depth 8));try{$stream=New-Object IO.FileStream($outputFull,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($receiptBytes,0,$receiptBytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}} catch [IO.IOException]{throw 'Restore receipt already exists or could not be created atomically.'};Write-Output $outputFull
