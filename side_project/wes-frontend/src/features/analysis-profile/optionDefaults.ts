import type { OptionField } from './types';
import type { OptionValues } from './DynamicOptionForm';

export function buildDefaults(fields: OptionField[]): OptionValues {
  return Object.fromEntries(fields.map((field) => [field.key, field.default]));
}
