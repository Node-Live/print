# How much of the NativeAOT exe the HTTP server costs: the same tiny program published three ways.
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP 'size-experiments'
New-Item -ItemType Directory -Force $work | Out-Null
$variants = @{
    'console' = 'System.Console.WriteLine("ready");'
    'tcplistener' = @'
var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 19234);
listener.Start();
listener.Stop();
System.Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new Answer("ready"), AnswerJson.Default.Answer));
record Answer(string State);
[System.Text.Json.Serialization.JsonSerializable(typeof(Answer))] partial class AnswerJson : System.Text.Json.Serialization.JsonSerializerContext;
'@
    'kestrel' = @'
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions());
builder.WebHost.UseKestrelCore().ConfigureKestrel(k => k.Listen(System.Net.IPAddress.Loopback, 19234));
var app = builder.Build();
app.Run(context => context.Response.WriteAsJsonAsync(new Answer("ready"), AnswerJson.Default.Answer));
await app.StartAsync();
await app.StopAsync();
record Answer(string State);
[System.Text.Json.Serialization.JsonSerializable(typeof(Answer))] partial class AnswerJson : System.Text.Json.Serialization.JsonSerializerContext;
'@
}
foreach ($name in 'console', 'tcplistener', 'kestrel') {
    $dir = Join-Path $work $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $framework = if ($name -eq 'kestrel') { '<ItemGroup><FrameworkReference Include="Microsoft.AspNetCore.App" /></ItemGroup>' } else { '' }
    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><PublishAot>true</PublishAot>
  <RuntimeIdentifier>win-x64</RuntimeIdentifier><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup>
  $framework
</Project>
"@ | Set-Content (Join-Path $dir "$name.csproj")
    $variants[$name] | Set-Content (Join-Path $dir 'Program.cs')
    dotnet publish $dir -c Release -o (Join-Path $dir 'out') -v q | Out-Null
    "{0,-12} {1:N2} MB" -f $name, ((Get-Item (Join-Path $dir "out\$name.exe")).Length / 1MB)
}
