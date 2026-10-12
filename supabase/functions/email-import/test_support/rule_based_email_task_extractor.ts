import {
  candidateContract,
  type CandidateEvidenceV1,
  type EmailCandidatePayloadV1,
  type EmailCandidateType,
  validateCandidateObject,
} from "../candidate_codec.ts";
import {
  type EmailExtractorInput,
  type EmailTaskExtractor,
  type PreparedExtractorInput,
  prepareExtractorInput,
} from "../extraction.ts";

interface CourseHint {
  readonly name: string | null;
  readonly code: string | null;
}

interface TemporalCandidate {
  readonly at?: string | null;
  readonly endAt?: string | null;
  readonly allDay?: boolean;
  readonly rawText?: string | null;
  readonly isRelative?: boolean;
  readonly warnings?: readonly string[];
}

/**
 * Deterministic, secret-free Japanese extractor for explicit tests only.
 * Production modules never import this file.
 */
export class RuleBasedEmailTaskExtractor implements EmailTaskExtractor {
  extract(input: EmailExtractorInput): Promise<EmailCandidatePayloadV1> {
    const prepared = prepareExtractorInput(input);
    const source = `${prepared.sanitizedSubject}\n${prepared.sanitizedContent}`;
    const candidateType = classifyCandidate(source);
    const warnings: string[] = prepared.ignoredUntrustedInstruction
      ? ["untrusted_instruction_ignored"]
      : [];

    const course = courseHint(source, warnings);
    const candidateTitle = title(prepared.sanitizedSubject, source);
    if (candidateTitle === null) warnings.push("missing_title");
    const temporal = temporalCandidate(
      source,
      candidateType,
      input.receivedAt,
      input.timezone,
    );
    warnings.push(...(temporal.warnings ?? []));
    const candidateLocation = labeledValue(
      source,
      ["場所", "会場", "教室"],
      candidateContract.maximumLocationCharacters,
    );
    const submissionUrl = uniqueHttpsUrl(source);

    const evidence: CandidateEvidenceV1[] = [
      {
        field: "candidate_type",
        text: excerpt(prepared.sanitizedSubject),
      },
      ...(candidateTitle === null
        ? []
        : [{ field: "title", text: excerpt(candidateTitle) }]),
      ...(course.name === null
        ? []
        : [{ field: "course_hint.name", text: excerpt(course.name) }]),
      ...(course.code === null
        ? []
        : [{ field: "course_hint.code", text: excerpt(course.code) }]),
      ...(temporal.rawText === null || temporal.rawText === undefined ? [] : [{
        field: candidateType === "assignment" ? "due.at" : "start_at",
        text: excerpt(temporal.rawText),
      }]),
      ...(candidateLocation === null
        ? []
        : [{ field: "location", text: excerpt(candidateLocation) }]),
      ...(submissionUrl === null
        ? []
        : [{ field: "submission_url", text: excerpt(submissionUrl) }]),
    ];

    const isAssignment = candidateType === "assignment";
    const isScheduled = candidateType === "exam" || candidateType === "event";
    const hasTemporalValue = temporal.at !== null &&
      temporal.at !== undefined;
    const dateTimeConfidence = hasTemporalValue
      ? (temporal.isRelative ? 0.82 : 0.94)
      : 0.15;
    const courseConfidence = course.name === null && course.code === null
      ? 0.25
      : 0.86;
    const titleConfidence = candidateTitle === null ? 0 : 0.88;
    const typeConfidence = candidateType === "unknown" ? 0.2 : 0.9;

    return Promise.resolve(validateCandidateObject({
      schema_version: "1.0",
      candidate_type: candidateType,
      title: candidateTitle,
      course_hint: course,
      due: {
        at: isAssignment ? temporal.at ?? null : null,
        all_day: isAssignment && (temporal.allDay ?? false),
        timezone: input.timezone,
        raw_text: isAssignment ? temporal.rawText ?? null : null,
      },
      start_at: isScheduled ? temporal.at ?? null : null,
      end_at: isScheduled ? temporal.endAt ?? null : null,
      location: candidateLocation,
      submission_url: submissionUrl,
      summary: null,
      suggested_reminders_minutes: hasTemporalValue
        ? (isAssignment ? [1_440, 180] : [1_440])
        : [],
      confidence: {
        overall: average([
          typeConfidence,
          titleConfidence,
          courseConfidence,
          dateTimeConfidence,
        ]),
        title: titleConfidence,
        course: courseConfidence,
        date_time: dateTimeConfidence,
      },
      evidence: evidence.slice(0, candidateContract.maximumEvidenceItems),
      warnings: [...new Set(warnings)],
      requires_user_confirmation: true,
    }));
  }
}

function classifyCandidate(source: string): EmailCandidateType {
  if (/(課題|レポート|宿題|提出期限)/.test(source)) return "assignment";
  if (/(試験|小テスト|テスト|考査)/.test(source)) return "exam";
  if (/(イベント|説明会|面談|講演|セミナー|ミーティング|交流会)/.test(source)) {
    return "event";
  }
  if (/(お知らせ|連絡|休講|変更案内|告知)/.test(source)) {
    return "announcement";
  }
  return "unknown";
}

function courseHint(source: string, warnings: string[]): CourseHint {
  const names = labeledValues(
    source,
    ["科目", "科目名", "授業", "授業名", "講義", "講義名"],
    candidateContract.maximumCourseNameCharacters,
  );
  let name: string | null = null;
  if (names.length === 1 && !looksAmbiguous(names[0]!)) {
    name = withoutParenthesizedCode(names[0]!);
  } else if (
    names.length > 1 || (names.length > 0 && looksAmbiguous(names[0]!))
  ) {
    warnings.push("ambiguous_course");
  } else {
    const bracket = /^\s*【([^】]+)】/m.exec(source)?.[1]?.trim();
    if (
      bracket !== undefined &&
      Array.from(bracket).length <=
        candidateContract.maximumCourseNameCharacters &&
      !/(重要|至急|お知らせ|案内)/.test(bracket)
    ) {
      name = bracket;
    }
  }

  const codes = labeledValues(
    source,
    ["科目コード", "授業コード", "講義コード"],
    candidateContract.maximumCourseCodeCharacters,
  );
  let code: string | null = null;
  if (codes.length === 1 && !looksAmbiguous(codes[0]!)) {
    code = codes[0]!;
  } else if (
    codes.length > 1 || (codes.length > 0 && looksAmbiguous(codes[0]!))
  ) {
    warnings.push("ambiguous_course");
  } else if (name !== null) {
    const match = /[（(]([A-Za-z]{2,8}[- ]?\d{2,6})[）)]/.exec(
      names[0] ?? "",
    );
    code = match?.[1]?.replaceAll(" ", "") ?? null;
  }
  return { name, code };
}

function title(subject: string, source: string): string | null {
  const labeled = labeledValue(
    source,
    ["課題名", "試験名", "イベント名", "件名"],
    candidateContract.maximumTitleCharacters,
  );
  if (labeled !== null) return labeled;
  const withoutCourse = subject.replace(/^\s*【[^】]+】\s*/, "").trim();
  if (
    withoutCourse.length === 0 ||
    Array.from(withoutCourse).length > candidateContract.maximumTitleCharacters
  ) {
    return null;
  }
  return withoutCourse;
}

function temporalCandidate(
  source: string,
  candidateType: EmailCandidateType,
  receivedAt: string,
  timezone: string,
): TemporalCandidate {
  const relevant =
    source.split("\n").find((line) =>
      /(期限|締切|日時|開催|開始|明日|明後日|今日|本日|\d{1,4}[年/-]\d{1,2})/
        .test(
          line,
        )
    )?.trim() ?? "";
  if (relevant.length === 0) return { warnings: ["missing_date_time"] };

  const warnings: string[] = [];
  const relative = /(明後日|明日|今日|本日)/.exec(relevant)?.[1] ?? null;
  const japaneseDate = /(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日/.exec(relevant);
  const numericDate = /(\d{4})[/-](\d{1,2})[/-](\d{1,2})/.exec(relevant);
  let year: number | null = null;
  let month: number | null = null;
  let day: number | null = null;
  let isRelative = false;

  if (relative !== null) {
    isRelative = true;
    warnings.push("relative_date");
    const receivedParts = localDateTimeParts(new Date(receivedAt), timezone);
    const delta = relative === "明日" ? 1 : relative === "明後日" ? 2 : 0;
    const shifted = new Date(Date.UTC(
      receivedParts.year,
      receivedParts.month - 1,
      receivedParts.day + delta,
    ));
    year = shifted.getUTCFullYear();
    month = shifted.getUTCMonth() + 1;
    day = shifted.getUTCDate();
  } else if (japaneseDate !== null) {
    year = japaneseDate[1] === undefined ? null : Number(japaneseDate[1]);
    month = Number(japaneseDate[2]);
    day = Number(japaneseDate[3]);
    if (year === null) warnings.push("ambiguous_year");
  } else if (numericDate !== null) {
    year = Number(numericDate[1]);
    month = Number(numericDate[2]);
    day = Number(numericDate[3]);
  } else {
    return { rawText: excerpt(relevant), warnings: ["ambiguous_date"] };
  }

  const timePattern = /(?:(午前|午後)\s*)?(\d{1,2})(?::|時)(\d{2})?(?:分)?/g;
  if (year === null) {
    if ([...relevant.matchAll(timePattern)].length === 0) {
      warnings.push("ambiguous_time");
    }
    return { rawText: excerpt(relevant), warnings };
  }
  if (
    month === null || day === null || !validCivilDate(year, month, day)
  ) {
    return { rawText: excerpt(relevant), warnings: ["ambiguous_date"] };
  }

  const timeMatches = [...relevant.matchAll(timePattern)];
  if (timeMatches.length === 0) {
    warnings.push("ambiguous_time");
    if (candidateType !== "assignment") {
      return { rawText: excerpt(relevant), isRelative, warnings };
    }
    const allDay = zonedLocalToUtc(year, month, day, 0, 0, timezone);
    return allDay === null
      ? { rawText: excerpt(relevant), warnings: ["ambiguous_date"] }
      : {
        at: allDay.toISOString(),
        allDay: true,
        rawText: excerpt(relevant),
        isRelative,
        warnings,
      };
  }

  const first = clock(timeMatches[0]!);
  if (first === null) {
    return { rawText: excerpt(relevant), warnings: ["ambiguous_time"] };
  }
  const start = zonedLocalToUtc(
    year,
    month,
    day,
    first.hour,
    first.minute,
    timezone,
  );
  if (start === null) {
    return { rawText: excerpt(relevant), warnings: ["ambiguous_time"] };
  }
  let endAt: string | null = null;
  if (timeMatches.length >= 2) {
    const second = clock(timeMatches[1]!);
    if (second !== null) {
      const end = zonedLocalToUtc(
        year,
        month,
        day,
        second.hour,
        second.minute,
        timezone,
      );
      if (end !== null && end.getTime() > start.getTime()) {
        endAt = end.toISOString();
      }
    }
  }
  return {
    at: start.toISOString(),
    endAt,
    rawText: excerpt(relevant),
    isRelative,
    warnings,
  };
}

function clock(
  match: RegExpMatchArray,
): { hour: number; minute: number } | null {
  let hour = Number(match[2]);
  const minute = Number(match[3] ?? 0);
  if (!Number.isInteger(hour) || hour > 23 || minute > 59) return null;
  if (match[1] === "午後" && hour < 12) hour += 12;
  if (match[1] === "午前" && hour === 12) hour = 0;
  return { hour, minute };
}

function validCivilDate(year: number, month: number, day: number): boolean {
  if (month < 1 || month > 12 || day < 1) return false;
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() + 1 === month &&
    date.getUTCDate() === day;
}

function localDateTimeParts(
  instant: Date,
  timezone: string,
): { year: number; month: number; day: number; hour: number; minute: number } {
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  const parts = Object.fromEntries(
    formatter.formatToParts(instant)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, Number(part.value)]),
  );
  return {
    year: parts.year,
    month: parts.month,
    day: parts.day,
    hour: parts.hour,
    minute: parts.minute,
  };
}

function zonedLocalToUtc(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  timezone: string,
): Date | null {
  const targetAsUtc = Date.UTC(year, month - 1, day, hour, minute, 0);
  let candidate = targetAsUtc;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const observed = localDateTimeParts(new Date(candidate), timezone);
    const observedAsUtc = Date.UTC(
      observed.year,
      observed.month - 1,
      observed.day,
      observed.hour,
      observed.minute,
      0,
    );
    candidate += targetAsUtc - observedAsUtc;
  }
  const result = new Date(candidate);
  const finalParts = localDateTimeParts(result, timezone);
  return finalParts.year === year && finalParts.month === month &&
      finalParts.day === day && finalParts.hour === hour &&
      finalParts.minute === minute
    ? result
    : null;
}

function uniqueHttpsUrl(source: string): string | null {
  const matches = new Set(
    [...source.matchAll(/https:\/\/[^\s<>"']+/g)]
      .map((match) => match[0].replace(/[。、，,.;；)）]+$/, "")),
  );
  if (matches.size !== 1) return null;
  const value = [...matches][0]!;
  return Array.from(value).length <=
      candidateContract.maximumSubmissionUrlCharacters
    ? value
    : null;
}

function labeledValue(
  source: string,
  labels: readonly string[],
  maximumCharacters: number,
): string | null {
  const values = labeledValues(source, labels, maximumCharacters);
  return values.length === 1 ? values[0]! : null;
}

function labeledValues(
  source: string,
  labels: readonly string[],
  maximumCharacters: number,
): string[] {
  const escapedLabels = labels.map((label) =>
    label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  ).join("|");
  const expression = new RegExp(
    `^(?:${escapedLabels})\\s*[:：]\\s*(.+?)\\s*$`,
    "gm",
  );
  return [...source.matchAll(expression)]
    .map((match) => match[1]!.trim())
    .filter((value) =>
      value.length > 0 && Array.from(value).length <= maximumCharacters
    )
    .filter((value, index, values) => values.indexOf(value) === index);
}

function looksAmbiguous(value: string): boolean {
  return /(?:[/／]|、|または|もしくは)/.test(value);
}

function withoutParenthesizedCode(value: string): string {
  return value
    .replace(/\s*[（(][A-Za-z]{2,8}[- ]?\d{2,6}[）)]\s*$/, "")
    .trim();
}

function excerpt(value: string): string {
  const normalized = value.replace(/\s+/g, " ").trim();
  return Array.from(normalized)
    .slice(0, candidateContract.maximumEvidenceTextCharacters)
    .join("");
}

function average(values: readonly number[]): number {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

// Re-exported only from this test-support module for deterministic fixture QA.
export const ruleBasedExtractorTestUtils = {
  localDateTimeParts,
  zonedLocalToUtc,
  prepare(input: EmailExtractorInput): PreparedExtractorInput {
    return prepareExtractorInput(input);
  },
};
