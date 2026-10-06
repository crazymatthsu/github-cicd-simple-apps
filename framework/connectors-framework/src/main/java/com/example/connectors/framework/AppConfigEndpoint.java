package com.example.connectors.framework;

import java.util.Map;

import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.core.env.ConfigurableEnvironment;

/**
 * {@code GET /actuator/appconfig}: the same masked summary as the start-up log, for
 * {@code run-compose.sh ... app-config} against a running stack (ADR-0016, ADR-0040). Unlike {@code /actuator/env}
 * it never shows a value that the summary would mask.
 */
@Endpoint(id = AppConfigEndpoint.ID)
public class AppConfigEndpoint {

    /** The endpoint id: {@code /actuator/appconfig}, the generic name the runtime scripts read first (ADR-0037). */
    public static final String ID = "appconfig";

    private final ConfigurableEnvironment environment;
    private final ConnectorIdentity identity;

    public AppConfigEndpoint(ConfigurableEnvironment environment, ConnectorIdentity identity) {
        this.environment = environment;
        this.identity = identity;
    }

    @ReadOperation
    public Map<String, Object> config() {
        return ConfigurationSummary.capture(environment, identity).asMap();
    }
}
