//! A minimal XLSX writer.
//!
//! Terminal database clients usually stop at CSV and let the user fight Excel
//! about encodings and about whether `007` is a number. Writing the real format
//! avoids both: strings stay strings, numbers stay numbers so `SUM` works, the
//! header row is frozen, and there is no encoding question because the file is
//! UTF-8 XML by definition.
//!
//! The sheet is assembled in memory, which the exporter warns about — a
//! spreadsheet cannot be streamed into a zip without knowing its size, and
//! Excel stops at about a million rows anyway.

use crate::export::writers::{render, RowWriter};
use crate::export::zip::ZipWriter;
use crate::export::ExportSpec;
use crate::protocol::{ColumnDesc, ValueClass};
use anyhow::Result;
use serde_json::Value as JsonValue;

/// Excel's own row ceiling; past it the file will not open.
const MAX_ROWS: usize = 1_048_575;

pub struct XlsxWriter {
    spec: ExportSpec,
    columns: Vec<ColumnDesc>,
    rows: Vec<Vec<Option<Cell>>>,
    truncated: bool,
}

#[derive(Clone)]
enum Cell {
    Number(String),
    Text(String),
    Bool(bool),
}

/// Escape text for XML content.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            // XML 1.0 forbids most control characters outright, so they are
            // dropped rather than written into a file Excel would reject.
            c if (c as u32) < 0x20 && c != '\t' && c != '\n' && c != '\r' => {}
            c => out.push(c),
        }
    }
    out
}

/// `A`, `B`, … `Z`, `AA`, … for a zero-based column index.
pub fn column_name(mut index: usize) -> String {
    let mut name = String::new();
    loop {
        name.insert(0, (b'A' + (index % 26) as u8) as char);
        if index < 26 {
            break;
        }
        index = index / 26 - 1;
    }
    name
}

impl XlsxWriter {
    pub fn new(spec: &ExportSpec, columns: &[ColumnDesc]) -> Self {
        Self {
            spec: spec.clone(),
            columns: columns.to_vec(),
            rows: Vec::new(),
            truncated: false,
        }
    }

    fn sheet_xml(&self) -> String {
        let mut xml = String::with_capacity(1024 + self.rows.len() * 64);
        xml.push_str(r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#);
        xml.push_str(
            r#"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#,
        );

        // Freeze the header so it stays visible while scrolling.
        if self.spec.header {
            xml.push_str(
                r#"<sheetViews><sheetView workbookViewId="0" tabSelected="1"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#,
            );
        }

        // Column widths from the header, so names are readable on open.
        xml.push_str("<cols>");
        for (index, column) in self.columns.iter().enumerate() {
            let width = (column.name.chars().count() + 4).clamp(10, 60);
            xml.push_str(&format!(
                r#"<col min="{0}" max="{0}" width="{1}" customWidth="1"/>"#,
                index + 1,
                width
            ));
        }
        xml.push_str("</cols>");

        xml.push_str("<sheetData>");

        let mut row_number = 1;
        if self.spec.header {
            xml.push_str(&format!(r#"<row r="{row_number}">"#));
            for (index, column) in self.columns.iter().enumerate() {
                xml.push_str(&format!(
                    r#"<c r="{}{}" t="inlineStr" s="1"><is><t xml:space="preserve">{}</t></is></c>"#,
                    column_name(index),
                    row_number,
                    escape(&column.name)
                ));
            }
            xml.push_str("</row>");
            row_number += 1;
        }

        for row in &self.rows {
            xml.push_str(&format!(r#"<row r="{row_number}">"#));
            for (index, cell) in row.iter().enumerate() {
                let reference = format!("{}{}", column_name(index), row_number);
                match cell {
                    // An empty cell is how a spreadsheet says "no value", which
                    // is exactly what NULL means; writing the placeholder text
                    // would turn it into a string.
                    None => {}
                    Some(Cell::Number(value)) => {
                        xml.push_str(&format!(r#"<c r="{reference}"><v>{value}</v></c>"#))
                    }
                    Some(Cell::Bool(flag)) => xml.push_str(&format!(
                        r#"<c r="{reference}" t="b"><v>{}</v></c>"#,
                        u8::from(*flag)
                    )),
                    Some(Cell::Text(value)) => xml.push_str(&format!(
                        r#"<c r="{reference}" t="inlineStr"><is><t xml:space="preserve">{}</t></is></c>"#,
                        escape(value)
                    )),
                }
            }
            xml.push_str("</row>");
            row_number += 1;
        }

        xml.push_str("</sheetData></worksheet>");
        xml
    }

    fn workbook_xml(&self) -> String {
        let name = escape(&self.spec.sheet_name);
        format!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="{name}" sheetId="1" r:id="rId1"/></sheets></workbook>"#
        )
    }
}

impl RowWriter for XlsxWriter {
    fn begin(&mut self, columns: &[ColumnDesc], _out: &mut Vec<u8>) -> Result<()> {
        if self.columns.is_empty() {
            self.columns = columns.to_vec();
        }
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        _out: &mut Vec<u8>,
    ) -> Result<()> {
        if self.rows.len() >= MAX_ROWS {
            self.truncated = true;
            return Ok(());
        }

        let cells = values
            .iter()
            .enumerate()
            .map(|(index, value)| {
                let column = &columns[index];
                render(value, column, &self.spec).map(|text| match column.class {
                    // Only a value that really parses as a number becomes one;
                    // an id like `007` stays text so Excel does not eat the
                    // leading zeros.
                    ValueClass::Number if text.parse::<f64>().is_ok() => Cell::Number(text),
                    ValueClass::Bool => match text.as_str() {
                        "true" | "t" | "1" => Cell::Bool(true),
                        "false" | "f" | "0" => Cell::Bool(false),
                        _ => Cell::Text(text),
                    },
                    _ => Cell::Text(text),
                })
            })
            .collect();

        self.rows.push(cells);
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) -> Result<()> {
        let mut zip = ZipWriter::new(Vec::new());

        zip.add(
            "[Content_Types].xml",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#,
        )?;

        zip.add(
            "_rels/.rels",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
        )?;

        zip.add(
            "xl/_rels/workbook.xml.rels",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#,
        )?;

        // Two styles: the default, and a bold one for the header row.
        zip.add(
            "xl/styles.xml",
            br#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>"#,
        )?;

        zip.add("xl/workbook.xml", self.workbook_xml().as_bytes())?;
        zip.add("xl/worksheets/sheet1.xml", self.sheet_xml().as_bytes())?;

        let bytes = zip.finish()?;
        out.extend_from_slice(&bytes);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spec() -> ExportSpec {
        serde_json::from_value(json!({
            "format": "xlsx",
            "destination": "/tmp/out.xlsx",
            "sql": "select 1",
        }))
        .unwrap()
    }

    #[test]
    fn names_columns_the_way_a_spreadsheet_does() {
        assert_eq!(column_name(0), "A");
        assert_eq!(column_name(25), "Z");
        assert_eq!(column_name(26), "AA");
        assert_eq!(column_name(27), "AB");
        assert_eq!(column_name(51), "AZ");
        assert_eq!(column_name(52), "BA");
        assert_eq!(column_name(701), "ZZ");
        assert_eq!(column_name(702), "AAA");
    }

    #[test]
    fn writes_a_zip_that_looks_like_a_workbook() {
        let columns = vec![
            ColumnDesc::new("id", "int", ValueClass::Number),
            ColumnDesc::new("name", "text", ValueClass::Text),
        ];
        let mut writer = XlsxWriter::new(&spec(), &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer
            .row(&columns, &[json!("1"), json!("Łódź")], &mut out)
            .unwrap();
        writer.finish(&mut out).unwrap();

        assert_eq!(&out[0..2], b"PK", "an xlsx is a zip");
        let text = String::from_utf8_lossy(&out);
        assert!(text.contains("[Content_Types].xml"));
        assert!(text.contains("xl/worksheets/sheet1.xml"));
    }

    #[test]
    fn keeps_numbers_numeric_and_ids_textual() {
        let columns = vec![
            ColumnDesc::new("amount", "numeric", ValueClass::Number),
            ColumnDesc::new("code", "text", ValueClass::Text),
        ];
        let mut writer = XlsxWriter::new(&spec(), &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer
            .row(&columns, &[json!("12.5"), json!("007")], &mut out)
            .unwrap();

        let sheet = writer.sheet_xml();
        assert!(sheet.contains("<v>12.5</v>"), "a number is a number");
        assert!(
            sheet.contains("<t xml:space=\"preserve\">007</t>"),
            "a code keeps its leading zeros"
        );
    }

    #[test]
    fn leaves_a_null_cell_empty() {
        let columns = vec![ColumnDesc::new("note", "text", ValueClass::Text)];
        let mut writer = XlsxWriter::new(&spec(), &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer.row(&columns, &[JsonValue::Null], &mut out).unwrap();

        let sheet = writer.sheet_xml();
        // Row 2 exists but holds no cell, which is how a spreadsheet says
        // "nothing here" as opposed to "an empty string here".
        assert!(sheet.contains(r#"<row r="2"></row>"#));
    }

    #[test]
    fn escapes_xml_and_drops_illegal_control_characters() {
        assert_eq!(escape("a & b <c>"), "a &amp; b &lt;c&gt;");
        assert_eq!(escape("a\u{0}b"), "ab");
        assert_eq!(escape("keep\ttab"), "keep\ttab");
    }

    #[test]
    fn freezes_the_header_row() {
        let columns = vec![ColumnDesc::text("a")];
        let writer = XlsxWriter::new(&spec(), &columns);
        assert!(writer.sheet_xml().contains(r#"state="frozen""#));
    }
}
