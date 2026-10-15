import { StyleSheet, Text, View } from 'react-native';
import { Verdict } from '../api/types';
import { plural } from '../lib/format';
import {
  headline,
  optionViews,
  OptionView,
  toneOf,
  tradeoffLines,
} from '../lib/verdictView';
import { ConfidenceBadge } from './ConfidenceBadge';
import { Theme, useTheme } from './theme';

interface Props {
  verdict: Verdict;
  /** For tests: pin the clock's locale and time zone. */
  timeOptions?: { locale?: string; timeZone?: string };
}

/**
 * The answer: "Leave now" or "Wait X minutes", what each choice costs and
 * saves, how sure the app is, and any heads-up. Stories 2-1 to 2-5.
 */
export function VerdictCard({ verdict, timeOptions }: Props) {
  const theme = useTheme();
  const tone = theme.tone[toneOf(verdict)];
  const options = optionViews(verdict, timeOptions);
  const tradeoff = tradeoffLines(verdict);

  return (
    <View
      style={[
        styles.card,
        { backgroundColor: theme.card, borderColor: theme.border },
      ]}
    >
      <View style={[styles.stripe, { backgroundColor: tone }]} />
      <View style={styles.body}>
        <Text
          accessibilityRole="header"
          style={[styles.headline, { color: tone }]}
        >
          {headline(verdict)}
        </Text>
        <Text style={[styles.reason, { color: theme.text }]}>
          {verdict.reason}
        </Text>

        {verdict.lateByMinutes !== undefined ? (
          <Text style={[styles.warning, { color: theme.tone.late }]}>
            You may arrive about {plural(verdict.lateByMinutes, 'minute')} late.
          </Text>
        ) : null}

        <View style={styles.options}>
          {options.map(option => (
            <OptionBox
              key={option.title}
              option={option}
              theme={theme}
              tone={tone}
            />
          ))}
        </View>

        {tradeoff.length > 0 ? (
          <View style={styles.tradeoff}>
            {tradeoff.map(line => (
              <Text
                key={line}
                style={[styles.tradeoffLine, { color: theme.muted }]}
              >
                {line}
              </Text>
            ))}
          </View>
        ) : null}

        {verdict.notes.map(note => (
          <Text key={note} style={[styles.note, { color: theme.muted }]}>
            {note}
          </Text>
        ))}

        <View style={styles.confidence}>
          <ConfidenceBadge
            confidence={verdict.confidence}
            reason={verdict.confidenceReason}
          />
        </View>
      </View>
    </View>
  );
}

function OptionBox({
  option,
  theme,
  tone,
}: {
  option: OptionView;
  theme: Theme;
  tone: string;
}) {
  return (
    <View
      style={[
        styles.option,
        option.recommended ? styles.optionOn : styles.optionOff,
        { borderColor: option.recommended ? tone : theme.border },
      ]}
    >
      <Text style={[styles.optionTitle, { color: theme.text }]}>
        {option.title}
      </Text>
      <Text style={[styles.optionLine, { color: theme.text }]}>
        {option.leave}
      </Text>
      <Text style={[styles.optionLine, { color: theme.text }]}>
        {option.arrive}
      </Text>
      <Text style={[styles.optionDrive, { color: theme.muted }]}>
        {option.drive}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: 18,
    borderWidth: 1,
    overflow: 'hidden',
    flexDirection: 'row',
  },
  stripe: { width: 8 },
  body: { flex: 1, padding: 18 },
  headline: { fontSize: 34, fontWeight: '800', letterSpacing: -0.5 },
  reason: { fontSize: 16, lineHeight: 23, marginTop: 6 },
  warning: { fontSize: 16, fontWeight: '700', marginTop: 10 },
  options: { flexDirection: 'row', marginTop: 16, gap: 10 },
  option: { flex: 1, borderRadius: 12, padding: 12 },
  optionOn: { borderWidth: 2 },
  optionOff: { borderWidth: 1 },
  optionTitle: { fontSize: 15, fontWeight: '700', marginBottom: 6 },
  optionLine: { fontSize: 15, lineHeight: 21 },
  optionDrive: { fontSize: 13, marginTop: 4 },
  tradeoff: { marginTop: 14 },
  tradeoffLine: { fontSize: 15, lineHeight: 22 },
  note: { fontSize: 14, lineHeight: 20, marginTop: 10 },
  confidence: { marginTop: 16 },
});
