import { Linking, StyleSheet, Text } from 'react-native';
import { useTheme } from './theme';

export const OPEN_METEO_URL = 'https://open-meteo.com/';
export const CC_BY_URL = 'https://creativecommons.org/licenses/by/4.0/';

/**
 * Open-Meteo's weather data is CC BY 4.0, which requires crediting it with a
 * link, linking the license, and saying that we changed the data.
 */
export function Attribution() {
  const theme = useTheme();
  const open = (url: string) => {
    Linking.openURL(url).catch(() => undefined);
  };
  const link = [styles.link, { color: theme.accent }];
  return (
    <Text style={[styles.text, { color: theme.muted }]}>
      <Text
        accessibilityRole="link"
        onPress={() => open(OPEN_METEO_URL)}
        style={link}
      >
        Weather data by Open-Meteo.com
      </Text>
      {' ('}
      <Text
        accessibilityRole="link"
        onPress={() => open(CC_BY_URL)}
        style={link}
      >
        CC BY 4.0
      </Text>
      {'). Changed: rain forecasts are turned into extra drive time.'}
    </Text>
  );
}

const styles = StyleSheet.create({
  text: { fontSize: 12, lineHeight: 17, marginTop: 8 },
  link: { textDecorationLine: 'underline' },
});
