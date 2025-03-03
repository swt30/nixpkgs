{ lib, stdenvNoCC, linkFarmFromDrvs, callPackage, nuget-to-nix, writeShellScript, makeWrapper, fetchurl, xml2, dotnetCorePackages, dotnetPackages, mkNugetSource, mkNugetDeps, cacert, srcOnly, symlinkJoin, coreutils }:

{ name ? "${args.pname}-${args.version}"
, pname ? name
, enableParallelBuilding ? true
, doCheck ? false
# Flags to pass to `makeWrapper`. This is done to avoid double wrapping.
, makeWrapperArgs ? []

# Flags to pass to `dotnet restore`.
, dotnetRestoreFlags ? []
# Flags to pass to `dotnet build`.
, dotnetBuildFlags ? []
# Flags to pass to `dotnet test`, if running tests is enabled.
, dotnetTestFlags ? []
# Flags to pass to `dotnet install`.
, dotnetInstallFlags ? []
# Flags to pass to `dotnet pack`.
, dotnetPackFlags ? []
# Flags to pass to dotnet in all phases.
, dotnetFlags ? []

# The path to publish the project to. When unset, the directory "$out/lib/$pname" is used.
, installPath ? null
# The binaries that should get installed to `$out/bin`, relative to `$out/lib/$pname/`. These get wrapped accordingly.
# Unfortunately, dotnet has no method for doing this automatically.
# If unset, all executables in the projects root will get installed. This may cause bloat!
, executables ? null
# Packs a project as a `nupkg`, and installs it to `$out/share`. If set to `true`, the derivation can be used as a dependency for another dotnet project by adding it to `projectReferences`.
, packNupkg ? false
# The packages project file, which contains instructions on how to compile it. This can be an array of multiple project files as well.
, projectFile ? null
# The NuGet dependency file. This locks all NuGet dependency versions, as otherwise they cannot be deterministically fetched.
# This can be generated by running the `passthru.fetch-deps` script.
, nugetDeps ? null
# A list of derivations containing nupkg packages for local project references.
# Referenced derivations can be built with `buildDotnetModule` with `packNupkg=true` flag.
# Since we are sharing them as nugets they must be added to csproj/fsproj files as `PackageReference` as well.
# For example, your project has a local dependency:
#     <ProjectReference Include="../foo/bar.fsproj" />
# To enable discovery through `projectReferences` you would need to add a line:
#     <ProjectReference Include="../foo/bar.fsproj" />
#     <PackageReference Include="bar" Version="*" Condition=" '$(ContinuousIntegrationBuild)'=='true' "/>
, projectReferences ? []
# Libraries that need to be available at runtime should be passed through this.
# These get wrapped into `LD_LIBRARY_PATH`.
, runtimeDeps ? []

# Tests to disable. This gets passed to `dotnet test --filter "FullyQualifiedName!={}"`, to ensure compatibility with all frameworks.
# See https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-test#filter-option-details for more details.
, disabledTests ? []
# The project file to run unit tests against. This is usually referenced in the regular project file, but sometimes it needs to be manually set.
# It gets restored and build, but not installed. You may need to regenerate your nuget lockfile after setting this.
, testProjectFile ? ""

# The type of build to perform. This is passed to `dotnet` with the `--configuration` flag. Possible values are `Release`, `Debug`, etc.
, buildType ? "Release"
# If set to true, builds the application as a self-contained - removing the runtime dependency on dotnet
, selfContainedBuild ? false
# The dotnet SDK to use.
, dotnet-sdk ? dotnetCorePackages.sdk_6_0
# The dotnet runtime to use.
, dotnet-runtime ? dotnetCorePackages.runtime_6_0
# The dotnet SDK to run tests against. This can differentiate from the SDK compiled against.
, dotnet-test-sdk ? dotnet-sdk
, ... } @ args:

assert projectFile == null -> throw "Defining the `projectFile` attribute is required. This is usually an `.csproj`, or `.sln` file.";

# TODO: Automatically generate a dependency file when a lockfile is present.
# This file is unfortunately almost never present, as Microsoft recommands not to push this in upstream repositories.
assert nugetDeps == null -> throw "Defining the `nugetDeps` attribute is required, as to lock the NuGet dependencies. This file can be generated by running the `passthru.fetch-deps` script.";

let
  inherit (callPackage ./hooks {
    inherit dotnet-sdk dotnet-test-sdk disabledTests nuget-source dotnet-runtime runtimeDeps buildType;
  }) dotnetConfigureHook dotnetBuildHook dotnetCheckHook dotnetInstallHook dotnetFixupHook;

  localDeps = if (projectReferences != [])
    then linkFarmFromDrvs "${name}-project-references" projectReferences
    else null;

  _nugetDeps = if lib.isDerivation nugetDeps
    then nugetDeps
    else mkNugetDeps { inherit name; nugetDeps = import nugetDeps; };

  # contains the actual package dependencies
  _dependenciesSource = mkNugetSource {
    name = "${name}-dependencies-source";
    description = "A Nuget source with the dependencies for ${name}";
    deps = [ _nugetDeps ] ++ lib.optional (localDeps != null) localDeps;
  };

  # this contains all the nuget packages that are implictly referenced by the dotnet
  # build system. having them as separate deps allows us to avoid having to regenerate
  # a packages dependencies when the dotnet-sdk version changes
  _sdkDeps = mkNugetDeps {
    name = "dotnet-sdk-${dotnet-sdk.version}-deps";
    nugetDeps = dotnet-sdk.passthru.packages;
  };

  _sdkSource = mkNugetSource {
    name = "dotnet-sdk-${dotnet-sdk.version}-source";
    deps = [ _sdkDeps ];
  };

  nuget-source = symlinkJoin {
    name = "${name}-nuget-source";
    paths = [ _dependenciesSource _sdkSource ];
  };
in stdenvNoCC.mkDerivation (args // {
  nativeBuildInputs = args.nativeBuildInputs or [] ++ [
    dotnetConfigureHook
    dotnetBuildHook
    dotnetCheckHook
    dotnetInstallHook
    dotnetFixupHook

    cacert
    makeWrapper
    dotnet-sdk
  ];

  makeWrapperArgs = args.makeWrapperArgs or [ ] ++ [
    "--prefix LD_LIBRARY_PATH : ${dotnet-sdk.icu}/lib"
  ];

  # Stripping breaks the executable
  dontStrip = args.dontStrip or true;

  # gappsWrapperArgs gets included when wrapping for dotnet, as to avoid double wrapping
  dontWrapGApps = args.dontWrapGApps or true;

  passthru = {
    inherit nuget-source;

    fetch-deps = let
      exclusions = dotnet-sdk.passthru.packages { fetchNuGet = attrs: attrs.pname; };
    in writeShellScript "fetch-${pname}-deps" ''
      set -euo pipefail
      export PATH="${lib.makeBinPath [ coreutils dotnet-sdk nuget-to-nix ]}"

      cd "$(dirname "''${BASH_SOURCE[0]}")"

      export HOME=$(mktemp -d)
      deps_file="''${1:-/tmp/${pname}-deps.nix}"

      store_src="${srcOnly args}"
      src="$(mktemp -d /tmp/${pname}.XXX)"
      cp -rT "$store_src" "$src"
      chmod -R +w "$src"

      trap "rm -rf $src $HOME" EXIT
      pushd "$src"

      export DOTNET_NOLOGO=1
      export DOTNET_CLI_TELEMETRY_OPTOUT=1

      mkdir -p "$HOME/nuget_pkgs"

      for project in "${lib.concatStringsSep "\" \"" ((lib.toList projectFile) ++ lib.optionals (testProjectFile != "") (lib.toList testProjectFile))}"; do
        dotnet restore "$project" \
          ${lib.optionalString (!enableParallelBuilding) "--disable-parallel"} \
          -p:ContinuousIntegrationBuild=true \
          -p:Deterministic=true \
          --packages "$HOME/nuget_pkgs" \
          ${lib.optionalString (dotnetRestoreFlags != []) (builtins.toString dotnetRestoreFlags)} \
          ${lib.optionalString (dotnetFlags != []) (builtins.toString dotnetFlags)}
      done

      echo "${lib.concatStringsSep "\n" exclusions}" > "$HOME/package_exclusions"

      echo "Writing lockfile..."
      nuget-to-nix "$HOME/nuget_pkgs" "$HOME/package_exclusions" > "$deps_file"
      echo "Succesfully wrote lockfile to: $deps_file"
    '';
  } // args.passthru or {};
})
