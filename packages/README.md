# packages

Save the connector packages here:

1. Sign in at <https://lambogenius.com/app/downloads/hl7-mllp-connector>.
2. Download `Lambogenius.MllpConnector.LogicApps.1.4.0.nupkg`. Its SHA-256 is shown next to the link.
3. Save it in this folder.

Sample 05 also needs the HL7 v2 Codec: download `Lambogenius.Hl7Codec.LogicApps.1.1.0.nupkg` from
<https://lambogenius.com/app/downloads/hl7-v2-codec> and save it here too.

The `nuget.config` at the repository root makes this folder a package source, so every sample finds the packages
here. Git ignores `.nupkg` files in this folder.

Check a file before you use it (PowerShell):

```powershell
(Get-FileHash packages/Lambogenius.MllpConnector.LogicApps.1.4.0.nupkg -Algorithm SHA256).Hash.ToLower()
```

NuGet caches a package by version. If you replace a package with a newer build of the same version, clear the
cached copy first: `dotnet nuget locals global-packages --clear`, or delete its folder under
`%USERPROFILE%\.nuget\packages`.
