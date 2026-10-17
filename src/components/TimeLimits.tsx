import { useState } from 'react';
import { ClockTime, suggestedTime } from '../lib/clockTime';
import { TimeLimitsCard } from './TimeLimitsCard';
import { TimePickerSheet } from './TimePickerSheet';

type Field = 'leaveBy' | 'arriveBy';

const COPY: Record<
  Field,
  { title: string; explanation: string; suggestMinutesAhead: number }
> = {
  leaveBy: {
    title: 'Leave by',
    explanation:
      'The latest you want to be on the road. The app will not tell you to wait past it.',
    suggestMinutesAhead: 30,
  },
  arriveBy: {
    title: 'Arrive by',
    explanation:
      'The latest you need to get there. The app will not suggest a plan that arrives later.',
    suggestMinutesAhead: 90,
  },
};

interface Props {
  leaveBy?: ClockTime;
  arriveBy?: ClockTime;
  /** A time was set, or cleared (undefined). */
  onChange: (field: Field, time: ClockTime | undefined) => void;
}

/** The Leave by and Arrive by rows, and the sheet that edits them. */
export function TimeLimits({ leaveBy, arriveBy, onChange }: Props) {
  // Which time the sheet is for, kept after it closes so the title does not
  // change while the sheet slides away.
  const [field, setField] = useState<Field>('leaveBy');
  const [open, setOpen] = useState(false);
  const edit = (next: Field) => {
    setField(next);
    setOpen(true);
  };
  const { title, explanation, suggestMinutesAhead } = COPY[field];
  const finish = (time: ClockTime | undefined) => {
    onChange(field, time);
    setOpen(false);
  };

  return (
    <>
      <TimeLimitsCard
        leaveBy={leaveBy}
        arriveBy={arriveBy}
        onEditLeaveBy={() => edit('leaveBy')}
        onEditArriveBy={() => edit('arriveBy')}
      />
      <TimePickerSheet
        visible={open}
        title={title}
        explanation={explanation}
        current={field === 'arriveBy' ? arriveBy : leaveBy}
        fallback={suggestedTime(new Date(), suggestMinutesAhead)}
        onSet={finish}
        onClear={() => finish(undefined)}
        onClose={() => setOpen(false)}
      />
    </>
  );
}
