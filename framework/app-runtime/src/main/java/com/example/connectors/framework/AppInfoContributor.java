package com.example.connectors.framework;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.boot.actuate.info.Info;
import org.springframework.boot.actuate.info.InfoContributor;

/**
 * Adds the identity to {@code /actuator/info} next to Boot's build (version, git sha) section, under
 * {@value #APP_SECTION}, the generic section the shared runtime scripts read (ADR-0015, ADR-0037, ADR-0040). The
 * framework no longer publishes the {@code connector} section; the scripts still accept it from images built before.
 */
public class AppInfoContributor implements InfoContributor {

    /** The identity section of {@code /actuator/info} (ADR-0037, ADR-0040). */
    public static final String APP_SECTION = "app";

    private final ConnectorIdentity identity;

    public AppInfoContributor(ConnectorIdentity identity) {
        this.identity = identity;
    }

    @Override
    public void contribute(Info.Builder builder) {
        Map<String, Object> section = new LinkedHashMap<>(identity.asTags());
        section.put("tuple", identity.tuple());
        section.put("complete", identity.isComplete());
        builder.withDetail(APP_SECTION, section);
    }
}
