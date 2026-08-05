import Foundation

/// Shared inline CSS for every self-contained HTML report this package
/// renders (`NightReport`, `TargetReport`) -- one dark theme, no external
/// resources, no `<script>` anywhere. Extracted here (R8-2) so a second
/// report type doesn't have to fork-and-drift the first one's stylesheet.
enum ReportStyle {
    static let css = """
      :root {
        --bg: #06081a; --card: #10142c; --text: #f2f3fb; --muted: #9096b8;
        --line: #262c4d; --accent: #9fb2e8; --accent2: #c7d3ff; --code-bg: #171b38;
        --good: #4fbf78; --warn: #ffb545; --bad: #ff5c5c;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        padding: 32px 20px;
      }
      main { max-width: 800px; margin: 0 auto; }
      h1 { font-size: 26px; margin: 0 0 4px; }
      h2 {
        font-size: 14px; text-transform: uppercase; letter-spacing: .04em;
        color: var(--muted); margin: 28px 0 10px;
      }
      .sub { color: var(--muted); margin: 0 0 20px; }
      .card {
        background: var(--card); border: 1px solid var(--line); border-radius: 12px;
        padding: 16px 18px; margin-bottom: 8px;
      }
      .grid { display: flex; flex-wrap: wrap; gap: 10px; }
      .stat {
        background: var(--card); border: 1px solid var(--line); border-radius: 10px;
        padding: 10px 14px; min-width: 140px;
      }
      .stat .label { color: var(--muted); font-size: 12px; margin-bottom: 3px; }
      .stat .value { font-size: 17px; font-weight: 600; }
      .stat.big .value { font-size: 28px; }
      table { width: 100%; border-collapse: collapse; font-size: 14px; }
      td, th { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--line); }
      .table-wrap { overflow-x: auto; margin: 6px 0 14px; }
      code {
        background: var(--code-bg); border-radius: 5px; padding: 1px 6px;
        font: 13px ui-monospace, SFMono-Regular, Menlo, monospace;
      }
      .timeline-bar {
        display: flex; height: 16px; width: 100%; border-radius: 6px; overflow: hidden;
        background: var(--code-bg); margin: 10px 0;
      }
      .timeline-bar .active { background: var(--good); }
      .timeline-bar .gap { background: var(--bad); }
      ul.notice { margin: 6px 0; padding-left: 20px; }
      ul.notice li { margin: 4px 0; }
      .muted { color: var(--muted); }
      .badge {
        display: inline-block; font-size: 12px; font-weight: 600; padding: 2px 9px;
        border-radius: 999px; margin-right: 6px;
      }
      .badge.good { background: rgba(79,191,120,.15); color: var(--good); }
      .badge.warn { background: rgba(255,181,69,.15); color: var(--warn); }
      .badge.bad { background: rgba(255,92,92,.15); color: var(--bad); }
      tr.highlight td { background: rgba(159,178,232,.08); }
      footer.report-footer {
        margin-top: 32px; padding-top: 12px; border-top: 1px solid var(--line);
        color: var(--muted); font-size: 12px;
      }
    """
}
