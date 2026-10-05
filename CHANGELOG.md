# Changelog

## [0.4.0](https://github.com/crazymatthsu/github-cicd-simple-apps/compare/v0.3.0...v0.4.0) (2026-10-05)


### Features

* **config-lint:** every box of a pool needs a pinned host key (ADR-0028) ([#20](https://github.com/crazymatthsu/github-cicd-simple-apps/issues/20)) ([5bfd9d5](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/5bfd9d56fefa49a3d4accf8ef364ca1df93774fe))
* **platform:** platform.yml declares every project value, and the tooling reads it (ADR-0030) ([#18](https://github.com/crazymatthsu/github-cicd-simple-apps/issues/18)) ([220ab95](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/220ab956376e3c873b0ade62fccebf927c1e122c))
* **runtime:** logs and data under /logs/&lt;user&gt;/&lt;project&gt;/, one directory per instance (ADR-0018) ([#17](https://github.com/crazymatthsu/github-cicd-simple-apps/issues/17)) ([dcdbdab](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/dcdbdab9eb80986bd0ad12d72f477ca27a41fa0a))

## [0.3.0](https://github.com/crazymatthsu/github-cicd-simple-apps/compare/v0.2.0...v0.3.0) (2026-10-05)


### Features

* **compose:** one compose template; config layers are files merged into one generated env (R-0008) ([16c96d4](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/16c96d4c498b537eb583e4a6400564c58ccd51de))
* **compose:** one compose template; config layers are files merged into one generated env (R-0008) ([75e23f0](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/75e23f07455a90f93ab46747106f8b99559d987f))

## [0.2.0](https://github.com/crazymatthsu/github-cicd-simple-apps/compare/v0.1.1...v0.2.0) (2026-10-04)


### Features

* **deploy:** versioned host layout /apps/&lt;user&gt;/versions/&lt;project&gt;/&lt;version&gt;/ with current (DL-41, DL-46) ([6f7f73f](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/6f7f73f4534edd84bbf3ee924b95a54751bf1fb8))
* **deploy:** versioned host layout /apps/&lt;user&gt;/versions/&lt;project&gt;/&lt;version&gt;/ with current (DL-41, DL-46) ([5e70e92](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/5e70e92ada415aa4ec4c727053db92fdd0460ac0))

## [0.1.1](https://github.com/crazymatthsu/github-cicd-simple-apps/compare/v0.1.0...v0.1.1) (2026-10-04)


### Bug Fixes

* **release:** create the SBOM output directory; allow a dispatch from a branch with the tag input ([e2375f7](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/e2375f7af9d7bfdd8fdca412498ce6f059ec9dc0))
* **release:** create the SBOM output directory; allow a dispatch from a branch with the tag input ([108b866](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/108b866279bd98f1288117c29f57714180040cbc))

## 0.1.0 (2026-10-04)


### Features

* **deploy:** no workflow writes to main — the GitHub Deployment is the record (DL-40) ([7ff412a](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/7ff412a6f9d18c6551df13932ed25d186fe56ced))
* **deploy:** no workflow writes to main — the GitHub Deployment is the record (DL-40) ([4491cda](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/4491cdaec4f972304718f0a8940ce0d447d2e430))
* extract the Deephaven connector apps from github-demo as a project repository ([4eb139c](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/4eb139c1ad7fc7262a78968b2a3292d9076c8597))
* extract the Deephaven connector apps from github-demo as a project repository ([24a33e0](https://github.com/crazymatthsu/github-cicd-simple-apps/commit/24a33e0269b512edd90fa67bba7525f9b85de63e))
