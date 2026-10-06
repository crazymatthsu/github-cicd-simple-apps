// Settings plugin `buildlogic.platform` (ADR-0030): reads platform.yml once per build, validates it, names the root
// project after it, includes every module under its apps_dir and framework/ (ADR-0006), and hands its project values
// to every project as `buildlogic.platform.<key>` extra properties (registry, project, group, appsDir, kinds,
// referenceApp, devEnvs, regions, stages, flows, propertyPrefixes, secretProperties). The convention plugins read those
// values; none hard-codes them.
buildlogic.PlatformSettings.apply(settings)
