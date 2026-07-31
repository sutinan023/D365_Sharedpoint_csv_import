$script:D365StrictUtf8 = New-Object Text.UTF8Encoding($false,$true)
if (-not ('D365.ReleaseStrictJson' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Globalization; using System.Text;
namespace D365 { public static class ReleaseStrictJson {
static string s; static int i; public static void Validate(string text){s=text;i=0;Value();Ws();if(i!=s.Length)Fail("trailing content");}
static void Ws(){while(i<s.Length&&char.IsWhiteSpace(s[i]))i++;} static bool Peek(char c){return i<s.Length&&s[i]==c;} static void Want(char c){Ws();if(!Peek(c))Fail("expected "+c);i++;}
static void Value(){Ws();if(i>=s.Length)Fail("unexpected end");char c=s[i];if(c=='{'){Obj();return;}if(c=='['){Arr();return;}if(c=='"'){Str();return;}if(Take("true")||Take("false")||Take("null"))return;Num();}
static void Obj(){i++;Ws();var keys=new HashSet<string>(StringComparer.Ordinal);if(Peek('}')){i++;return;}while(true){string k=Str();if(!keys.Add(k))Fail("duplicate object key: "+k);Ws();Want(':');Value();Ws();if(Peek('}')){i++;return;}Want(',');}}
static void Arr(){i++;Ws();if(Peek(']')){i++;return;}while(true){Value();Ws();if(Peek(']')){i++;return;}Want(',');}}
static string Str(){Ws();Want('"');var b=new StringBuilder();while(i<s.Length){char c=s[i++];if(c=='"')return b.ToString();if(c<32)Fail("control character");if(c!='\\'){b.Append(c);continue;}if(i>=s.Length)Fail("incomplete escape");char e=s[i++];switch(e){case '"':case '\\':case '/':b.Append(e);break;case 'b':b.Append('\b');break;case 'f':b.Append('\f');break;case 'n':b.Append('\n');break;case 'r':b.Append('\r');break;case 't':b.Append('\t');break;case 'u':if(i+4>s.Length)Fail("unicode escape");int n;if(!int.TryParse(s.Substring(i,4),NumberStyles.HexNumber,CultureInfo.InvariantCulture,out n))Fail("unicode escape");b.Append((char)n);i+=4;break;default:Fail("escape");break;}}Fail("unterminated string");return null;}
static void Num(){int start=i;if(Peek('-'))i++;if(i>=s.Length)Fail("number");if(Peek('0'))i++;else{if(i>=s.Length||s[i]<'1'||s[i]>'9')Fail("number");while(i<s.Length&&char.IsDigit(s[i]))i++;}if(Peek('.')){i++;if(i>=s.Length||!char.IsDigit(s[i]))Fail("number");while(i<s.Length&&char.IsDigit(s[i]))i++;}if(Peek('e')||Peek('E')){i++;if(Peek('+')||Peek('-'))i++;if(i>=s.Length||!char.IsDigit(s[i]))Fail("number");while(i<s.Length&&char.IsDigit(s[i]))i++;}if(i==start)Fail("value");}
static bool Take(string x){if(i+x.Length<=s.Length&&string.CompareOrdinal(s,i,x,0,x.Length)==0){i+=x.Length;return true;}return false;} static void Fail(string m){throw new FormatException("Strict JSON "+m+" at "+i);}
}}
'@
}
function Get-D365Sha256([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Read-D365StrictJsonSnapshot([string]$Path,[string]$Label){
    try{$bytes=[IO.File]::ReadAllBytes($Path);$text=$script:D365StrictUtf8.GetString($bytes)}catch{throw "$Label cannot be read as strict UTF-8 JSON."}
    if($text.Length-gt0-and[int][char]$text[0]-eq0xFEFF){$text=$text.Substring(1)}
    try{[D365.ReleaseStrictJson]::Validate($text)}catch{throw "$Label failed strict JSON validation: $($_.Exception.Message)"}
    try{$value=$text|ConvertFrom-Json}catch{throw "$Label is not valid JSON."}
    if($null-eq$value){throw "$Label is not a JSON object."}
    [pscustomobject]@{Bytes=$bytes;Text=$text;Value=$value;Hash=(Get-D365Sha256 $bytes);Path=[IO.Path]::GetFullPath($Path)}
}
function Get-D365FullPath([string]$Path){[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}
function Test-D365PathEqual([string]$Left,[string]$Right){[string]::Equals((Get-D365FullPath $Left),(Get-D365FullPath $Right),[StringComparison]::OrdinalIgnoreCase)}
function Assert-D365NoReparse([string]$Path,[switch]$AllowMissingLeaf){
    $cursor=Get-D365FullPath $Path;if($AllowMissingLeaf-and-not(Test-Path -LiteralPath $cursor)){$cursor=Split-Path -Parent $cursor}
    while($cursor){if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Canonical audit path contains a reparse point.'}};$parent=Split-Path -Parent $cursor;if(-not$parent-or$parent-ceq$cursor){break};$cursor=$parent}
}
function Assert-D365DirectChild([string]$Path,[string]$Root){$full=Get-D365FullPath $Path;$rootFull=Get-D365FullPath $Root;if((Split-Path -Parent $full)-ine$rootFull){throw 'Approval receipt path is outside the canonical audit root.'};$full}
function Get-D365ApprovalRootKind([string]$Path){if(Test-D365PathEqual $Path 'C:\xampp\backups\d365\release-approvals'){'LOCAL';return};if(Test-D365PathEqual $Path '\\100.1.1.166\c$\xampp\backups\d365\release-approvals'){'UNC';return};$null}
function Assert-D365ProtectedAcl([string]$Path,[string[]]$AllowedWriterSids,[switch]$RequireProtected){
    $acl=Get-Acl -LiteralPath $Path;if($RequireProtected-and-not$acl.AreAccessRulesProtected){throw 'Canonical audit root ACL must disable inheritance.'}
    try{$owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value}catch{throw 'Audit ACL owner SID could not be determined.'}
    if($owner-notin$AllowedWriterSids){throw 'Audit ACL owner is not an allowed writer SID.'}
    $writeMask=[int64](2-bor4-bor16-bor64-bor256-bor65536-bor262144-bor524288)
    foreach($ace in $acl.Access){if($ace.AccessControlType-ne[Security.AccessControl.AccessControlType]::Allow){continue};try{$sid=$ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value}catch{throw 'Audit ACL identity could not be translated.'};if(([int64]$ace.FileSystemRights-band$writeMask)-ne0-and$sid-notin$AllowedWriterSids){throw "Audit ACL grants write rights to an unapproved SID: $sid"}}
}
function Get-D365ManifestProjects($Manifest){
    $names=@('D365_Sharedpoint_csv_import','D365_file_csv_import','finance_report');$actual=@($Manifest.projects.PSObject.Properties.Name|Sort-Object);if(($actual-join "`n")-cne(($names|Sort-Object)-join "`n")){throw 'Release manifest must contain exactly the three approved projects.'}
    $result=[ordered]@{};foreach($name in $names){$sha=[string]$Manifest.projects.$name.git_sha;if($sha-notmatch'^[0-9a-f]{40}$'){throw "Release manifest contains an invalid Git SHA for $name."};$result[$name]=[ordered]@{git_sha=$sha}}
    $result
}
