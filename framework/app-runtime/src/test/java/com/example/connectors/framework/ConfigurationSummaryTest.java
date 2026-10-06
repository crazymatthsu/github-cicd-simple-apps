package com.example.connectors.framework;

import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.TreeMap;

import org.junit.jupiter.api.Test;

import org.springframework.core.env.MapPropertySource;
import org.springframework.core.env.StandardEnvironment;

import static org.assertj.core.api.Assertions.assertThat;

class ConfigurationSummaryTest {

    /** A platform resource as the build writes it, with only the given property_prefixes (ADR-0042). */
    private static Properties platform(String propertyPrefixes) {
        Properties properties = new Properties();
        properties.setProperty("property_prefixes", propertyPrefixes);
        return properties;
    }

    @Test
    void showsTheEffectiveConnectorConfigurationWithSecretsMasked() {
        StandardEnvironment environment = new StandardEnvironment();
        environment.getPropertySources().addFirst(new MapPropertySource(
                "Config resource 'file [/config/common/application.yml]' via location 'optional:file:/config/common/application.yml'",
                Map.of("connector.source.port", 1433, "connector.source.poll-interval", "15s")));
        environment.getPropertySources().addFirst(new MapPropertySource(
                "Config resource 'file [/config/instance/application.yml]' via location 'optional:file:/config/instance/application.yml'",
                Map.of("connector.source.poll-interval", "5s", "connector.sink.type", "amps")));
        environment.getPropertySources().addFirst(new MapPropertySource("secrets", Map.of(
                "spring.datasource.password", "s3cr3t-value", "connector.sink.password", "an0ther-value")));
        ConnectorIdentity identity = new ConnectorIdentity("us-dev", "cash", "source-database", "trades-db-to-amps");

        // The framework's own root, as a project built on it declares it in platform.yml property_prefixes.
        ConfigurationSummary summary = ConfigurationSummary.capture(environment, identity,
                ConfigurationSummary.prefixes(platform("connector")));

        assertThat(summary.layers()).containsExactly("/config/common/application.yml", "/config/instance/application.yml");
        assertThat(summary.properties())
                .containsEntry("connector.source.poll-interval", "5s")
                .containsEntry("connector.source.port", "1433")
                .containsEntry("connector.sink.type", "amps")
                .containsEntry("connector.sink.password", SecretMasker.MASK)
                .containsEntry("spring.datasource.password", SecretMasker.MASK);
        String text = summary.render();
        assertThat(text).contains("Connector us-dev/cash/source-database/trades-db-to-amps")
                .contains("connector.source.poll-interval = 5s")
                .doesNotContain("s3cr3t-value", "an0ther-value");
        assertThat(summary.asMap()).containsEntry("identity", "us-dev/cash/source-database/trades-db-to-amps");
    }

    @Test
    void theRootsShownArePlatformYmlsPropertyPrefixesThenTheDatasource() {
        Properties resource = PlatformResource.read(getClass().getClassLoader());
        assertThat(resource).as("the build writes " + PlatformResource.RESOURCE + " from platform.yml").isNotNull();
        List<String> declared = PlatformResource.list(resource, "property_prefixes");

        assertThat(declared).as("platform.yml property_prefixes is a non-empty list").isNotEmpty();
        assertThat(ConfigurationSummary.PREFIXES)
                .startsWith(declared.toArray(String[]::new))
                .endsWith("spring.datasource");
        assertThat(ConfigurationSummary.prefixes(platform("orders, acme.billing")))
                .containsExactly("orders", "acme.billing", "spring.datasource");
        // Without the resource (a module whose jar was not built) the datasource alone is shown.
        assertThat(ConfigurationSummary.prefixes(null)).containsExactly("spring.datasource");
    }

    @Test
    void anotherProjectsRootsAreShownAndNoOthers() {
        StandardEnvironment environment = new StandardEnvironment();
        // Only the layer below: nothing of the test JVM's own environment.
        environment.getPropertySources().remove(StandardEnvironment.SYSTEM_ENVIRONMENT_PROPERTY_SOURCE_NAME);
        environment.getPropertySources().remove(StandardEnvironment.SYSTEM_PROPERTIES_PROPERTY_SOURCE_NAME);
        environment.getPropertySources().addFirst(new MapPropertySource("layer", Map.of(
                "orders.feed.url", "https://feed.example.com", "orders.feed.token", "t0ken-value",
                "connector.source.host", "db", "spring.datasource.url", "jdbc:h2:mem:x")));

        ConfigurationSummary summary = ConfigurationSummary.capture(environment,
                new ConnectorIdentity("local", "none", "orders-feed", "none"),
                ConfigurationSummary.prefixes(platform("orders")));

        assertThat(summary.properties())
                .containsOnlyKeys("orders.feed.url", "orders.feed.token", "spring.datasource.url")
                .containsEntry("orders.feed.token", SecretMasker.MASK);
    }

    @Test
    void anIncompleteIdentityIsFlagged() {
        ConfigurationSummary summary = ConfigurationSummary.capture(new StandardEnvironment(),
                new ConnectorIdentity("local", "none", "source-kafka", "none"));

        assertThat(summary.render()).contains("identity incomplete").contains("none (jar defaults only)");
    }

    @Test
    void anEmptySummaryNamesTheRootsItShows() {
        ConfigurationSummary summary = new ConfigurationSummary(
                new ConnectorIdentity("local", "none", "source-kafka", "none"), List.of(), new TreeMap<>());

        assertThat(summary.render())
                .contains("(no property under " + String.join(", ", ConfigurationSummary.PREFIXES) + ")");
    }
}
