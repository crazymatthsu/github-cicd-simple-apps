package com.example.connectors.framework;

import java.util.List;
import java.util.Properties;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SecretMaskerTest {

    /** A platform resource as the build writes it, with only the given secret_properties (ADR-0042). */
    private static Properties platform(String secretProperties) {
        Properties properties = new Properties();
        properties.setProperty("secret_properties", secretProperties);
        return properties;
    }

    /** Another project's secret properties: the masker names none of its own. */
    private static final List<String> ACME =
            SecretMasker.secretProperties(platform("acme.feed.username, acme.kafka.sasl"));

    /** The built-in names only, as without the platform resource. */
    private static final List<String> BUILT_IN = SecretMasker.secretProperties(null);

    @ParameterizedTest
    @ValueSource(strings = {
            "spring.datasource.password", "spring.datasource.username", "SPRING_DATASOURCE_PASSWORD",
            "SPRING_DATASOURCE_USERNAME", "acme.sink.api-key", "acme.deephaven.token", "acme.tls.keystore.password",
            "some.client-secret", "vault.credentials.role", "private-key" })
    void masksSpringsCredentialsAndSecretLookingKeysInEveryProject(String key) {
        assertThat(SecretMasker.isSecret(key)).isTrue();
        assertThat(SecretMasker.isSecret(key, BUILT_IN)).isTrue();
        assertThat(SecretMasker.mask(key, "hunter2")).isEqualTo(SecretMasker.MASK);
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "acme.feed.username", "ACME_FEED_USERNAME", "acme.kafka.sasl", "acme.kafka.sasl.jaas-config",
            "acme.kafka.sasl.mechanism" })
    void masksTheSecretPropertiesOfPlatformYmlAndEveryKeyBelowThem(String key) {
        assertThat(SecretMasker.isSecret(key, ACME)).isTrue();
        assertThat(SecretMasker.isSecret(key, BUILT_IN)).as("a project's own name is no secret to another").isFalse();
    }

    @Test
    void theSecretPropertiesAreSpringsThenThoseOfTheJarsPlatformResource() {
        Properties resource = PlatformResource.read(getClass().getClassLoader());
        assertThat(resource).as("the build writes " + PlatformResource.RESOURCE + " from platform.yml").isNotNull();
        List<String> declared = PlatformResource.list(resource, "secret_properties");

        assertThat(SecretMasker.secretProperties())
                .startsWith("spring.datasource.username", "spring.datasource.password")
                .containsAll(declared);
        declared.forEach(name -> assertThat(SecretMasker.isSecret(name)).as(name).isTrue());
        assertThat(BUILT_IN).containsExactly("spring.datasource.username", "spring.datasource.password");
        assertThat(ACME).containsExactly("spring.datasource.username", "spring.datasource.password",
                "acme.feed.username", "acme.kafka.sasl");
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "connector.source.host", "connector.source.table", "connector.sink.deephaven.table",
            "connector.source.poll-interval", "spring.datasource.url", "compare.key-columns", "connector.sink.type",
            "acme.feed.host" })
    void showsEverythingElse(String key) {
        assertThat(SecretMasker.isSecret(key, ACME)).isFalse();
        assertThat(SecretMasker.isSecret(key)).isFalse();
        assertThat(SecretMasker.mask(key, "value")).isEqualTo("value");
    }

    @Test
    void masksCredentialsInsideUrls() {
        assertThat(SecretMasker.mask("spring.datasource.url",
                "jdbc:sqlserver://sql:1433;databaseName=trades;user=sa;password=p@ss;encrypt=true"))
                .isEqualTo("jdbc:sqlserver://sql:1433;databaseName=trades;user=sa;password=******;encrypt=true");
        assertThat(SecretMasker.maskUrlCredentials("https://svc:t0ken@example.com/path"))
                .isEqualTo("https://svc:******@example.com/path");
    }

    @Test
    void nullStaysVisibleAsNull() {
        assertThat(SecretMasker.mask("connector.source.host", null)).isEqualTo("null");
    }
}
