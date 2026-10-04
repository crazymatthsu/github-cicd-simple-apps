// Settings plugin `buildlogic.git-version` (D1 §6.10, D4 §6.1–§6.2): derives project.version from git on
// every invocation — no version file exists anywhere. One release line per repository (D12 §6.1): tags
// vX.Y.Z, every project (VersionLine.FAMILY). -Pversion=<v> overrides it (experiments only; never used by
// workflows). Each project also receives extra properties used by the other
// convention plugins: buildlogic.versionKind, buildlogic.imageTags, buildlogic.gitSha, buildlogic.gitSha7,
// buildlogic.gitDirty, buildlogic.gitBranch, buildlogic.gitCommitTime, buildlogic.version.<line>.
buildlogic.GitVersionSettings.apply(settings)
