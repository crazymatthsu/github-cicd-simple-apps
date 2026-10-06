package com.example.connectors.framework;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Properties;
import java.util.regex.Pattern;

/**
 * Decides which configuration values are printed as {@value #MASK} (ADR-0013): every key under a secret property
 * name (usernames included, they rotate with their password) and every key with a secret-looking segment
 * ({@code password}, {@code secret}, {@code token}, {@code credential}, {@code *key}). Credentials embedded in URLs
 * are masked in the value itself.
 *
 * <p>The secret property names are Spring's datasource credentials, built in, and the project's own: platform.yml
 * {@code secret_properties}, which the build writes into every jar (ADR-0042). The segment rule is built in.
 */
public final class SecretMasker {

    public static final String MASK = "******";

    /** Spring's own secret properties, built in (ADR-0042): the datasource credentials of any Spring Boot app. */
    static final List<String> BUILT_IN_SECRET_PROPERTIES =
            List.of("spring.datasource.username", "spring.datasource.password");

    private static final Pattern SECRET_SEGMENT = Pattern.compile(
            "^(.*(password|passwd|secret|token|credential).*|pwd|.*key)$");

    private static final Pattern URL_PASSWORD = Pattern.compile("(?i)((?:password|pwd)=)[^;&]*");
    private static final Pattern URL_USER_INFO = Pattern.compile("(://[^/@:]+:)[^/@]*@");

    private SecretMasker() {
    }

    /** The secret property names of this app, read once from the jar's platform resource. */
    private static final class Platform {
        static final List<String> SECRET_PROPERTIES =
                secretProperties(PlatformResource.read(SecretMasker.class.getClassLoader()));
    }

    /** The secret property names this app masks: Spring's datasource credentials, then platform.yml's. */
    public static List<String> secretProperties() {
        return Platform.SECRET_PROPERTIES;
    }

    /**
     * The built-in names followed by the {@code secret_properties} of the platform resource {@code platform}; the
     * built-in names only when there is none (a unit test of a module whose jar was not built).
     */
    static List<String> secretProperties(Properties platform) {
        List<String> names = new ArrayList<>(BUILT_IN_SECRET_PROPERTIES);
        names.addAll(PlatformResource.list(platform, PlatformResource.SECRET_PROPERTIES));
        return names.stream().distinct().toList();
    }

    /** True when the value of {@code key} (dotted, relaxed or environment-variable form) must not be shown. */
    public static boolean isSecret(String key) {
        return isSecret(key, Platform.SECRET_PROPERTIES);
    }

    /** {@link #isSecret(String)} against the secret property names {@code secretProperties}. */
    static boolean isSecret(String key, List<String> secretProperties) {
        String normalised = normalise(key);
        for (String property : secretProperties) {
            String secret = normalise(property);
            if (normalised.equals(secret) || normalised.startsWith(secret + ".")) {
                return true;
            }
        }
        for (String segment : normalised.split("\\.")) {
            if (SECRET_SEGMENT.matcher(segment).matches()) {
                return true;
            }
        }
        return false;
    }

    /** The printable form of a configuration value. */
    public static String mask(String key, Object value) {
        if (value == null) {
            return "null";
        }
        if (isSecret(key)) {
            return MASK;
        }
        return maskUrlCredentials(String.valueOf(value));
    }

    /** {@code jdbc:...;password=x} and {@code scheme://user:pass@host} lose their credentials. */
    public static String maskUrlCredentials(String value) {
        String masked = URL_PASSWORD.matcher(value).replaceAll("$1" + MASK);
        return URL_USER_INFO.matcher(masked).replaceAll("$1" + MASK + "@");
    }

    /**
     * Lower case, {@code _} as the separator of environment-variable names, {@code -} and {@code [n]} dropped:
     * {@code SPRING_DATASOURCE_PASSWORD}, {@code spring.datasource.password} and
     * {@code spring.data-source.password} compare equal after {@link #isSecret}'s segment rules.
     */
    static String normalise(String key) {
        String k = key.toLowerCase(Locale.ROOT);
        if (!k.contains(".") && k.contains("_")) {
            k = k.replace('_', '.');
        }
        return k.replaceAll("\\[\\d+]", "").replace("-", "").replace("_", "");
    }
}
