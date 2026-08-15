//! A minimal ZIP writer, enough for the XLSX container.
//!
//! Entries are deflated, because a spreadsheet is XML and a hundred thousand
//! rows of it compresses by roughly ten to one — the difference between a file
//! you can email and one you cannot.

use crate::export::checksum::crc32;
use anyhow::Result;
use flate2::write::DeflateEncoder;
use flate2::Compression;
use std::io::Write;

struct Entry {
    name: String,
    offset: u32,
    size: u32,
    compressed_size: u32,
    crc: u32,
}

pub struct ZipWriter<W: Write> {
    writer: W,
    entries: Vec<Entry>,
    offset: u32,
}

impl<W: Write> ZipWriter<W> {
    pub fn new(writer: W) -> Self {
        Self {
            writer,
            entries: Vec::new(),
            offset: 0,
        }
    }

    /// Append one deflated file.
    pub fn add(&mut self, name: &str, data: &[u8]) -> Result<()> {
        let crc = crc32(data);
        let size = data.len() as u32;
        let offset = self.offset;

        let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(data)?;
        let compressed = encoder.finish()?;
        let compressed_size = compressed.len() as u32;

        let mut header = Vec::with_capacity(30 + name.len());
        header.extend_from_slice(&0x0403_4b50u32.to_le_bytes()); // local file header
        header.extend_from_slice(&20u16.to_le_bytes()); // version needed
        header.extend_from_slice(&0u16.to_le_bytes()); // flags
        header.extend_from_slice(&8u16.to_le_bytes()); // deflate
        header.extend_from_slice(&0u16.to_le_bytes()); // time
        header.extend_from_slice(&0u16.to_le_bytes()); // date
        header.extend_from_slice(&crc.to_le_bytes());
        header.extend_from_slice(&compressed_size.to_le_bytes());
        header.extend_from_slice(&size.to_le_bytes());
        header.extend_from_slice(&(name.len() as u16).to_le_bytes());
        header.extend_from_slice(&0u16.to_le_bytes()); // extra length
        header.extend_from_slice(name.as_bytes());

        self.writer.write_all(&header)?;
        self.writer.write_all(&compressed)?;
        self.offset += header.len() as u32 + compressed_size;

        self.entries.push(Entry {
            name: name.to_string(),
            offset,
            size,
            compressed_size,
            crc,
        });
        Ok(())
    }

    /// Write the central directory and close.
    pub fn finish(mut self) -> Result<W> {
        let directory_offset = self.offset;
        let mut directory = Vec::new();

        for entry in &self.entries {
            directory.extend_from_slice(&0x0201_4b50u32.to_le_bytes()); // central header
            directory.extend_from_slice(&20u16.to_le_bytes()); // version made by
            directory.extend_from_slice(&20u16.to_le_bytes()); // version needed
            directory.extend_from_slice(&0u16.to_le_bytes()); // flags
            directory.extend_from_slice(&8u16.to_le_bytes()); // deflate
            directory.extend_from_slice(&0u16.to_le_bytes()); // time
            directory.extend_from_slice(&0u16.to_le_bytes()); // date
            directory.extend_from_slice(&entry.crc.to_le_bytes());
            directory.extend_from_slice(&entry.compressed_size.to_le_bytes());
            directory.extend_from_slice(&entry.size.to_le_bytes());
            directory.extend_from_slice(&(entry.name.len() as u16).to_le_bytes());
            directory.extend_from_slice(&0u16.to_le_bytes()); // extra
            directory.extend_from_slice(&0u16.to_le_bytes()); // comment
            directory.extend_from_slice(&0u16.to_le_bytes()); // disk
            directory.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
            directory.extend_from_slice(&0u32.to_le_bytes()); // external attrs
            directory.extend_from_slice(&entry.offset.to_le_bytes());
            directory.extend_from_slice(entry.name.as_bytes());
        }

        self.writer.write_all(&directory)?;

        let mut end = Vec::with_capacity(22);
        end.extend_from_slice(&0x0605_4b50u32.to_le_bytes()); // end of central directory
        end.extend_from_slice(&0u16.to_le_bytes()); // disk
        end.extend_from_slice(&0u16.to_le_bytes()); // start disk
        end.extend_from_slice(&(self.entries.len() as u16).to_le_bytes());
        end.extend_from_slice(&(self.entries.len() as u16).to_le_bytes());
        end.extend_from_slice(&(directory.len() as u32).to_le_bytes());
        end.extend_from_slice(&directory_offset.to_le_bytes());
        end.extend_from_slice(&0u16.to_le_bytes()); // comment length

        self.writer.write_all(&end)?;
        self.writer.flush()?;
        Ok(self.writer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_a_readable_archive() {
        let mut zip = ZipWriter::new(Vec::new());
        zip.add("a.txt", b"hello").unwrap();
        zip.add("dir/b.txt", b"world").unwrap();
        let bytes = zip.finish().unwrap();

        // Local header, then the payload, then the central directory and the
        // end-of-central-directory record.
        assert_eq!(&bytes[0..4], &0x0403_4b50u32.to_le_bytes());
        assert!(bytes.windows(9).any(|window| window == b"dir/b.txt"));
        assert_eq!(
            &bytes[bytes.len() - 22..bytes.len() - 18],
            &0x0605_4b50u32.to_le_bytes()
        );

        // Two entries recorded in the end record.
        let count = u16::from_le_bytes([bytes[bytes.len() - 14], bytes[bytes.len() - 13]]);
        assert_eq!(count, 2);
    }

    #[test]
    fn stores_the_crc_of_each_entry() {
        let mut zip = ZipWriter::new(Vec::new());
        zip.add("a.txt", b"123456789").unwrap();
        let bytes = zip.finish().unwrap();
        let crc = u32::from_le_bytes([bytes[14], bytes[15], bytes[16], bytes[17]]);
        assert_eq!(crc, 0xCBF43926);
    }
}
