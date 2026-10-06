package com.example.connectors.framework;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.net.URL;
import java.util.Arrays;
import java.util.List;
import java.util.Properties;

/**
 * The values of platform.yml that the build writes into every jar as {@value #RESOURCE} (buildlogic.java-conventions,
 * ADR-0030, ADR-0042): the identity vocabulary that {@link ConnectorIdentity} checks, the app's own property roots
 * that {@link ConfigurationSummary} shows ({@value #PROPERTY_PREFIXES}) and the project's secret properties that
 * {@link SecretMasker} masks ({@value #SECRET_PROPERTIES}).
 */
final class PlatformResource {

    static final String RESOURCE = ConnectorIdentity.Vocabulary.RESOURCE;
    static final String PROPERTY_PREFIXES = "property_prefixes";
    static final String SECRET_PROPERTIES = "secret_properties";

    private PlatformResource() {
    }

    /** The resource as {@code loader} finds it, or {@code null} when it is not on the classpath (no jar was built). */
    static Properties read(ClassLoader loader) {
        URL url = loader.getResource(RESOURCE);
        if (url == null) {
            return null;
        }
        Properties properties = new Properties();
        try (InputStream in = url.openStream()) {
            properties.load(in);
        }
        catch (IOException e) {
            throw new UncheckedIOException("Cannot read " + url, e);
        }
        return properties;
    }

    /** The comma-separated list under {@code key}, trimmed; empty when the key or the resource is absent. */
    static List<String> list(Properties properties, String key) {
        if (properties == null) {
            return List.of();
        }
        return Arrays.stream(properties.getProperty(key, "").split(","))
                .map(String::trim)
                .filter(value -> !value.isEmpty())
                .toList();
    }
}
