import { useColorScheme } from 'react-native';
import { Confidence } from '../api/types';
import { Tone } from '../lib/verdictView';

export interface Theme {
  dark: boolean;
  background: string;
  card: string;
  text: string;
  muted: string;
  border: string;
  chip: string;
  accent: string;
  onAccent: string;
  tone: Record<Tone, string>;
  confidence: Record<Confidence, string>;
}

const LIGHT: Theme = {
  dark: false,
  background: '#f3f5f8',
  card: '#ffffff',
  text: '#13171c',
  muted: '#5a6572',
  border: '#dde2e8',
  chip: '#e8ecf1',
  accent: '#2f6fed',
  onAccent: '#ffffff',
  tone: { go: '#17803d', wait: '#2f6fed', late: '#c2410c' },
  confidence: { High: '#17803d', Medium: '#a16207', Low: '#b42318' },
};

const DARK: Theme = {
  dark: true,
  background: '#0c0f13',
  card: '#171b21',
  text: '#f1f4f8',
  muted: '#9ca6b2',
  border: '#2a3038',
  chip: '#232932',
  accent: '#5b93ff',
  onAccent: '#0c0f13',
  tone: { go: '#4ade80', wait: '#7aa7ff', late: '#fb923c' },
  confidence: { High: '#4ade80', Medium: '#facc15', Low: '#f87171' },
};

export const useTheme = (): Theme =>
  useColorScheme() === 'dark' ? DARK : LIGHT;
