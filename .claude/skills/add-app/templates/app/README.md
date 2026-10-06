# __APP_NAME__

__APP_SUMMARY__. On start-up it logs its identity `<env>/<flow>/__APP_NAME__/<AppInstance>` and the effective
configuration with secrets masked, and serves the actuator on port 8080 (ADR-0015, ADR-0016).

## Build and run

```bash
./gradlew :__APP_NAME__:build          # unit tests, bootJar
./gradlew :__APP_NAME__:buildImage     # needs Docker or Podman
scripts/run-compose.sh local <flow> __APP_NAME__ <AppInstance> start
scripts/run-compose.sh local <flow> __APP_NAME__ <AppInstance> health
scripts/run-compose.sh local <flow> __APP_NAME__ <AppInstance> down
```

`scripts/run-compose.sh` is the one operations CLI of every app (ADR-0017); `--help` lists every command.
Configuration lives in `config/<env>/<flow>/__APP_NAME__/`, never here (ADR-0011).

## Configuration keys

| Key | Layer | Meaning |
|---|---|---|
| | | (the app's own properties, one row each; endpoints and names only, never a secret, ADR-0013) |
