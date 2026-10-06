package com.example.connectors.framework;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.boot.actuate.info.Info;
import org.springframework.boot.actuate.info.InfoContributor;

/**
 * Adds the identity to {@code /actuator/info} next to Boot's build (version, git sha) section, as one map under two
 * names: {@value #APP_SECTION}, the generic section the shared runtime scripts read first, and
 * {@value #CONNECTOR_SECTION}, the framework's own name, which they still accept (ADR-0015, ADR-0037).
 */
public class ConnectorInfoContributor implements InfoContributor {

    /** The generic identity section of {@code /actuator/info} (ADR-0037). */
    public static final String APP_SECTION = "app";

    /** The framework's identity section, kept until the framework's names are decided (ADR-0037). */
    public static final String CONNECTOR_SECTION = "connector";

    private final ConnectorIdentity identity;

    public ConnectorInfoContributor(ConnectorIdentity identity) {
        this.identity = identity;
    }

    @Override
    public void contribute(Info.Builder builder) {
        Map<String, Object> section = new LinkedHashMap<>(identity.asTags());
        section.put("tuple", identity.tuple());
        section.put("complete", identity.isComplete());
        // One map under both names, so the two sections cannot disagree.
        Map<String, Object> shared = Collections.unmodifiableMap(section);
        builder.withDetail(CONNECTOR_SECTION, shared);
        builder.withDetail(APP_SECTION, shared);
    }
}
