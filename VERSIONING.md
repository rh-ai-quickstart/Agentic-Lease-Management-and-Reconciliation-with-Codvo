# Helm Chart Versioning Policy

This document describes the versioning policy for NeIO LeasingOps Helm charts.

## Semantic Versioning

All Helm charts in this repository follow [Semantic Versioning 2.0.0](https://semver.org/).

Version format: `MAJOR.MINOR.PATCH`

### Version Components

| Component | When to Increment | Examples |
|-----------|-------------------|----------|
| **MAJOR** | Breaking changes that require user action | API changes, removed values, incompatible upgrades |
| **MINOR** | New features, backward-compatible additions | New agents, new configuration options, new dependencies |
| **PATCH** | Bug fixes, security patches, documentation | Template fixes, default value updates, typo corrections |

## Chart Version vs App Version

Helm charts have two version fields:

```yaml
# Chart.yaml
version: 1.2.3      # Chart version - follows this policy
appVersion: "2.0.0" # Application version - tracks NeIO LeasingOps release
```

- **Chart Version**: Tracks changes to Helm templates, values, and deployment configurations
- **App Version**: Tracks the NeIO LeasingOps application version being deployed

These versions are independent. A chart bug fix increments the chart version but not the app version.

## Version Examples

### MAJOR Version Increment (Breaking Changes)

Increment MAJOR version when changes require user intervention:

- Removing a configuration value from `values.yaml`
- Changing the structure of existing values
- Requiring new mandatory values
- Changing resource naming conventions
- Incompatible database schema migrations
- Removing support for older Kubernetes/OpenShift versions

```yaml
# Before: 1.5.2
# After:  2.0.0

# Example: Restructuring database configuration
# OLD
postgresql:
  host: localhost
  port: 5432

# NEW (breaking - requires user to update values)
database:
  postgresql:
    connection:
      host: localhost
      port: 5432
```

### MINOR Version Increment (New Features)

Increment MINOR version for backward-compatible additions:

- Adding new optional configuration values
- Adding new AI agents
- Adding new Kubernetes resources (optional)
- Supporting new OpenShift AI features
- Adding new dependencies (optional)

```yaml
# Before: 1.5.2
# After:  1.6.0

# Example: Adding new agent configuration
ai:
  agents:
    contractIntake:
      enabled: true
    # NEW - optional, defaults provided
    auditTrailAgent:
      enabled: true
      retentionDays: 365
```

### PATCH Version Increment (Bug Fixes)

Increment PATCH version for backward-compatible fixes:

- Fixing template rendering bugs
- Correcting default values
- Documentation updates
- Security patches (non-breaking)
- Performance improvements in templates

```yaml
# Before: 1.5.2
# After:  1.5.3

# Example: Fixing incorrect default memory limit
resources:
  limits:
    # Was: 2Gi (caused OOM)
    # Now: 4Gi (correct default)
    memory: 4Gi
```

## Pre-release Versions

Pre-release versions may be published for testing:

| Type | Format | Purpose |
|------|--------|---------|
| Alpha | `1.2.0-alpha.1` | Early testing, unstable |
| Beta | `1.2.0-beta.1` | Feature complete, testing |
| RC | `1.2.0-rc.1` | Release candidate, final testing |

Pre-release versions are not recommended for production use.

## Dependency Versioning

Charts may depend on other charts. Dependency versions should:

1. Use caret ranges for minor updates: `^1.2.0`
2. Use tilde ranges for patch updates only: `~1.2.0`
3. Pin exact versions for stability: `1.2.3`

```yaml
# Chart.yaml
dependencies:
  - name: postgresql
    version: "~14.0.0"    # Accept 14.0.x patches
    repository: https://charts.bitnami.com/bitnami
  - name: redis
    version: "^18.0.0"    # Accept 18.x.x minor updates
    repository: https://charts.bitnami.com/bitnami
  - name: qdrant
    version: "0.9.1"      # Pinned for stability
    repository: https://qdrant.github.io/qdrant-helm
```

## Release Process

### 1. Version Bump

Update version in `Chart.yaml`:

```bash
# For patch release
./scripts/bump-version.sh patch

# For minor release
./scripts/bump-version.sh minor

# For major release
./scripts/bump-version.sh major
```

### 2. Changelog Update

Update `CHANGELOG.md` with changes:

```markdown
## [1.6.0] - 2026-02-03

### Added
- New audit trail agent configuration
- Support for OpenShift 4.15

### Changed
- Updated default memory limits for worker

### Fixed
- Template rendering issue with empty labels
```

### 3. Tag Release

```bash
git tag -a v1.6.0 -m "Release v1.6.0"
git push origin v1.6.0
```

### 4. Publish Chart

Charts are automatically published to the Helm repository when a tag is pushed.

## Upgrade Compatibility Matrix

| From Version | To Version | Upgrade Path |
|--------------|------------|--------------|
| 1.x.x | 1.x.x | Direct upgrade, review release notes |
| 1.x.x | 2.x.x | Follow migration guide in `docs/upgrade.md` |
| 0.x.x | 1.x.x | Clean install recommended |

## Deprecation Policy

When deprecating features:

1. **Announce**: Document deprecation in release notes
2. **Warn**: Add deprecation warnings in templates for 2 minor versions
3. **Remove**: Remove in next major version

```yaml
# Example deprecation warning in templates
{{- if .Values.deprecated.oldValue }}
{{- fail "DEPRECATED: 'deprecated.oldValue' has been removed in v2.0.0. Use 'new.value' instead." }}
{{- end }}
```

## Version History

| Version | Release Date | Notes |
|---------|--------------|-------|
| 1.0.0 | 2026-01-15 | Initial release |
| 1.1.0 | 2026-01-22 | Added OpenShift AI support |
| 1.2.0 | 2026-02-01 | Added new AI agents |

## Questions

For versioning questions or concerns, please open an issue or contact support@codvo.ai.
