package com.example.connectors.framework;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.net.URL;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.regex.Pattern;

import org.springframework.core.env.PropertyResolver;

/**
 * The identity tuple {@code <env>/<flow>/<AppName>/<AppInstance>} of one running pipeline (ADR-0003).
 *
 * <p>The deployer sets it through the environment variables {@code APP_ENV}, {@code APP_FLOW},
 * {@code APP_NAME} and {@code APP_INSTANCE} (the compose env layers / Helm values); it must equal the config-tree path
 * the instance was started from. Without them (a laptop, a unit test) the identity is
 * {@code local/none/<spring.application.name>/none}, which {@link #isComplete()} reports as incomplete.
 *
 * <p>The env and the flow are checked against the regions, stages and flows of platform.yml, which the build writes
 * into every jar ({@link Vocabulary}), so the app accepts exactly the identities the deploy tools accept (ADR-0030).
 */
public record ConnectorIdentity(String env, String flow, String app, String instance) {

    public static final String ENV_VARIABLE = "APP_ENV";
    public static final String FLOW_VARIABLE = "APP_FLOW";
    public static final String NAME_VARIABLE = "APP_NAME";
    public static final String INSTANCE_VARIABLE = "APP_INSTANCE";

    /** Marker for a flow or instance that was not set (only accepted in the {@code local} env). */
    public static final String UNSET = "none";

    /** The env of a laptop or a unit test; every other env is {@code <region>-<stage>} (ADR-0003). */
    public static final String LOCAL = "local";

    static final Pattern TOKEN = Pattern.compile("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$");
    static final int MAX_APP_NAME = 20;
    static final int MAX_APP_INSTANCE = 32;

    public ConnectorIdentity {
        Vocabulary vocabulary = Vocabulary.current();
        require(env != null && vocabulary.isEnv(env),
                ENV_VARIABLE + "='" + env + "' must be local or <region>-<stage> with a region of " + vocabulary.regions()
                        + " and a stage of " + vocabulary.stages() + " (platform.yml)");
        boolean local = LOCAL.equals(env);
        require(flow != null && (vocabulary.flows().contains(flow) || (local && UNSET.equals(flow))),
                FLOW_VARIABLE + "='" + flow + "' must be one of " + vocabulary.flows() + " (platform.yml)");
        require(app != null && TOKEN.matcher(app).matches() && app.length() <= MAX_APP_NAME,
                NAME_VARIABLE + "='" + app + "' must be lower-case kebab-case, at most " + MAX_APP_NAME + " characters");
        require(instance != null && TOKEN.matcher(instance).matches() && instance.length() <= MAX_APP_INSTANCE
                        && !instance.chars().allMatch(Character::isDigit)
                        && (local || !UNSET.equals(instance)),
                INSTANCE_VARIABLE + "='" + instance + "' must be a lower-case kebab-case business name (never a bare"
                        + " number), at most " + MAX_APP_INSTANCE + " characters");
    }

    /**
     * Reads the identity from the environment. {@code APP_NAME}, when set, must equal
     * {@code spring.application.name}: an image started with another app's env layers fails fast.
     */
    public static ConnectorIdentity from(PropertyResolver environment) {
        String applicationName = blankToNull(environment.getProperty("spring.application.name"));
        String appName = blankToNull(environment.getProperty(NAME_VARIABLE));
        if (appName != null && applicationName != null && !appName.equals(applicationName)) {
            throw new IllegalStateException(NAME_VARIABLE + "=" + appName + " but this is the " + applicationName
                    + " image: the compose env layers or Helm values of another app were used");
        }
        String app = appName != null ? appName : (applicationName != null ? applicationName : "unknown");
        return new ConnectorIdentity(
                valueOr(environment, ENV_VARIABLE, LOCAL),
                valueOr(environment, FLOW_VARIABLE, UNSET),
                app,
                valueOr(environment, INSTANCE_VARIABLE, UNSET));
    }

    /** True when flow and instance were set by a deployer (never the {@code none} markers). */
    public boolean isComplete() {
        return !UNSET.equals(flow) && !UNSET.equals(instance);
    }

    /** {@code us-dev/cash/source-database/trades-db-to-amps}. */
    public String tuple() {
        return env + "/" + flow + "/" + app + "/" + instance;
    }

    /** The compose project name {@code <env>-<flow>-<app>-<instance>} (ADR-0003). */
    public String composeProject() {
        return env + "-" + flow + "-" + app + "-" + instance;
    }

    /** The Helm release / Deployment name {@code <app>-<instance>} (ADR-0003). */
    public String releaseName() {
        return app + "-" + instance;
    }

    /** The Deephaven table-name prefix {@code <flow>_<instance>_} with dashes as underscores (ADR-0003). */
    public String tablePrefix() {
        return (flow + "_" + instance + "_").replace('-', '_');
    }

    /** {@code env, flow, app, instance}: metric tags, MDC fields, log fields and labels (ADR-0003). */
    public Map<String, String> asTags() {
        Map<String, String> tags = new LinkedHashMap<>();
        tags.put("env", env);
        tags.put("flow", flow);
        tags.put("app", app);
        tags.put("instance", instance);
        return tags;
    }

    @Override
    public String toString() {
        return tuple();
    }

    private static String valueOr(PropertyResolver environment, String name, String fallback) {
        String value = blankToNull(environment.getProperty(name));
        return value != null ? value : fallback;
    }

    private static String blankToNull(String value) {
        return (value == null || value.isBlank()) ? null : value.trim();
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new IllegalArgumentException("Invalid connector identity: " + message);
        }
    }

    /**
     * The identity vocabulary of platform.yml (ADR-0003, ADR-0030). The build (buildlogic.java-conventions) writes its
     * regions, stages and flows into {@value #RESOURCE} of every jar; an app without it fails at start-up.
     */
    record Vocabulary(List<String> regions, List<String> stages, List<String> flows) {

        static final String RESOURCE = "META-INF/platform/identity.properties";

        private static volatile Vocabulary current;

        /** {@code local}, or {@code <region>-<stage>} with a region and a stage of the vocabulary. */
        boolean isEnv(String env) {
            int dash = env.indexOf('-');
            return LOCAL.equals(env)
                    || (dash > 0 && regions.contains(env.substring(0, dash)) && stages.contains(env.substring(dash + 1)));
        }

        static Vocabulary current() {
            Vocabulary vocabulary = current;
            if (vocabulary == null) {
                vocabulary = load(ConnectorIdentity.class.getClassLoader());
                current = vocabulary;
            }
            return vocabulary;
        }

        static Vocabulary load(ClassLoader loader) {
            URL url = loader.getResource(RESOURCE);
            if (url == null) {
                throw new IllegalStateException(RESOURCE + " is not on the classpath: the build generates it from "
                        + "platform.yml (buildlogic.java-conventions, ADR-0030)");
            }
            Properties properties = new Properties();
            try (InputStream in = url.openStream()) {
                properties.load(in);
            } catch (IOException e) {
                throw new UncheckedIOException("Cannot read " + url, e);
            }
            return of(properties, url.toString());
        }

        static Vocabulary of(Properties properties, String source) {
            return new Vocabulary(list(properties, "regions", source), list(properties, "stages", source),
                    list(properties, "flows", source));
        }

        private static List<String> list(Properties properties, String key, String source) {
            List<String> values = Arrays.stream(properties.getProperty(key, "").split(","))
                    .map(String::trim)
                    .filter(value -> !value.isEmpty())
                    .toList();
            if (values.isEmpty()) {
                throw new IllegalStateException(source + ": " + key + " is empty: the build writes it from platform.yml "
                        + "(ADR-0030)");
            }
            return values;
        }
    }
}
