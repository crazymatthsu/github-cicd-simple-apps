# The chart of __APP_NAME__ (provisional, ADR-0019)

One release `__APP_NAME__-<AppInstance>` per instance directory of the config tree, in the namespace of its flow.
Values layers: this chart's `values.yaml`, then `config/<env>/<flow>/__APP_NAME__/_helm-values.app.yaml`, then
`<AppInstance>/_helm-values.instance.yaml` (`image.tag`, the identity, `env`), with the `application.<layer>.yml`
layers passed as file values. `scripts/helm-deploy-instance.sh` builds the flag list for every caller: config-lint,
the kind deployment test and deploy-dev. Charts are identical but for the name and the description; a change to one
is a change to all (ADR-0019 rule 2).
