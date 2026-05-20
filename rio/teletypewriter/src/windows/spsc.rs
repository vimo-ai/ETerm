// Single-producer single-consumer buffer for Rust

use std::cell::UnsafeCell;
use std::io::{self, Read, Write};
use std::mem;
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};

struct SpscBuffer {
    buf: UnsafeCell<Box<[u8]>>,
    len: AtomicUsize,
}

impl SpscBuffer {
    fn new(size: usize) -> Self {
        Self {
            buf: UnsafeCell::new(vec![0; size].into_boxed_slice()),
            len: AtomicUsize::new(0),
        }
    }

    fn len(&self) -> usize {
        self.len.load(Ordering::SeqCst)
    }

    fn capacity(&self) -> usize {
        unsafe { &*self.buf.get() }.len()
    }

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn is_full(&self) -> bool {
        self.len() == self.capacity()
    }
}

/// Consumer of the ringbuffer.
pub struct SpscBufferReader {
    start: usize,
    buffer: Rc<SpscBuffer>,
}

impl SpscBufferReader {
    /// Get length of contents currently in the buffer
    #[allow(unused)]
    pub fn len(&self) -> usize {
        self.buffer.len()
    }

    /// Get total capacity of the buffer
    #[allow(unused)]
    pub fn capacity(&self) -> usize {
        self.buffer.capacity()
    }

    /// Check whether the buffer is currently empty
    #[allow(unused)]
    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    /// Check whether the buffer is currently empty
    #[allow(unused)]
    pub fn is_full(&self) -> bool {
        self.buffer.is_full()
    }

    /// Read data from the buffer. Returns number of bytes read.
    pub fn read_to_slice(&mut self, buf: &mut [u8]) -> usize {
        use std::cmp::min;

        #[allow(clippy::transmute_ptr_to_ref)]
        let ringbuf: &mut Box<[u8]> = unsafe { mem::transmute(self.buffer.buf.get()) };

        let ringbuf_capacity = ringbuf.len();
        let ringbuf_len = self.buffer.len.load(Ordering::SeqCst);

        // Max number of bytes we might read
        let max_read_size = min(buf.len(), ringbuf_len);
        let contents_until_end = ringbuf_capacity - self.start;
        let read_size = min(max_read_size, contents_until_end);

        buf[..read_size].copy_from_slice(&ringbuf[self.start..self.start + read_size]);
        self.start = (self.start + read_size) % ringbuf_capacity;
        self.buffer.len.fetch_sub(read_size, Ordering::SeqCst);

        read_size
    }
}

impl Read for SpscBufferReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        Ok(self.read_to_slice(buf))
    }
}

unsafe impl Sync for SpscBufferReader {}
unsafe impl Send for SpscBufferReader {}

/// Producer for the ringbuffer
pub struct SpscBufferWriter {
    end: usize,
    buffer: Rc<SpscBuffer>,
}

impl SpscBufferWriter {
    /// Get length of contents currently in the buffer
    #[allow(unused)]
    pub fn len(&self) -> usize {
        self.buffer.len()
    }

    /// Get total capacity of the buffer
    #[allow(unused)]
    pub fn capacity(&self) -> usize {
        self.buffer.capacity()
    }

    /// Check whether the buffer is currently empty
    #[allow(unused)]
    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    /// Check whether the buffer is currently empty
    pub fn is_full(&self) -> bool {
        self.buffer.is_full()
    }

    /// Write data to the buffer. Returns number of bytes written.
    pub fn write_from_slice(&mut self, buf: &[u8]) -> usize {
        use std::cmp::min;

        #[allow(clippy::transmute_ptr_to_ref)]
        let ringbuf: &mut Box<[u8]> = unsafe { mem::transmute(self.buffer.buf.get()) };

        let ringbuf_capacity = ringbuf.len();
        let ringbuf_len = self.buffer.len.load(Ordering::SeqCst);

        // Max number of bytes we might read
        let max_write_size = min(buf.len(), ringbuf_capacity - ringbuf_len);
        let space_until_end = ringbuf_capacity - self.end;
        let write_size = min(max_write_size, space_until_end);

        ringbuf[self.end..self.end + write_size].copy_from_slice(&buf[..write_size]);
        self.end = (self.end + write_size) % ringbuf_capacity;
        self.buffer.len.fetch_add(write_size, Ordering::SeqCst);

        write_size
    }
}

unsafe impl Sync for SpscBufferWriter {}
unsafe impl Send for SpscBufferWriter {}

impl Write for SpscBufferWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        Ok(self.write_from_slice(buf))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Create a new SPSC buffer pair.
///
/// The producer and consumer can safely be transferred between threads; the
/// expected use case is that one thread will be writing and one will be reading.
///
/// The underlying buffer's size is synchronised using an atomic. The producer
/// and consumer have methods to query the size and the capacity, which is
/// guaranteed to be consistent between threads but may not be sufficient to
/// prevent races depending on what you are trying to achieve.
///
/// See the mio-anonymous-pipes crate for example usage.
pub fn spsc_buffer(size: usize) -> (SpscBufferWriter, SpscBufferReader) {
    let buffer = Rc::new(SpscBuffer::new(size));

    let producer = SpscBufferWriter {
        end: 0,
        buffer: buffer.clone(),
    };
    let consumer = SpscBufferReader { start: 0, buffer };

    (producer, consumer)
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_spsc_buffer_basic() {
        let buf = [1u8; 100];

        let (mut producer, mut consumer) = spsc_buffer(60);

        assert!(producer.is_empty());
        assert!(consumer.is_empty());

        assert_eq!(producer.len(), 0);
        assert_eq!(consumer.len(), 0);

        assert_eq!(producer.capacity(), 60);
        assert_eq!(consumer.capacity(), 60);

        let mut out_buf = [0u8; 100];

        assert_eq!(producer.write_from_slice(&buf), 60);
        assert_eq!(producer.len(), 60);
        assert_eq!(consumer.len(), 60);

        assert_eq!(consumer.read_to_slice(&mut out_buf), 60);
        assert_eq!(producer.len(), 0);
        assert_eq!(consumer.len(), 0);

        assert_eq!(producer.write_from_slice(&buf[60..]), 40);
        assert_eq!(producer.len(), 40);
        assert_eq!(consumer.len(), 40);

        assert_eq!(consumer.read_to_slice(&mut out_buf[60..]), 40);
        assert_eq!(producer.len(), 0);
        assert_eq!(consumer.len(), 0);

        assert_eq!(&buf[..], &out_buf[..]);
    }

    #[test]
    fn test_spsc_empty_read() {
        let (_, mut consumer) = spsc_buffer(64);
        let mut buf = [0u8; 32];
        assert_eq!(consumer.read_to_slice(&mut buf), 0);
    }

    #[test]
    fn test_spsc_full_write_returns_zero() {
        let (mut producer, _consumer) = spsc_buffer(8);
        let data = [0xAA; 8];
        assert_eq!(producer.write_from_slice(&data), 8);
        assert!(producer.is_full());
        assert_eq!(producer.write_from_slice(&[0xFF]), 0);
    }

    #[test]
    fn test_spsc_wraparound() {
        let (mut producer, mut consumer) = spsc_buffer(8);
        let mut out = [0u8; 8];

        // Fill half
        assert_eq!(producer.write_from_slice(&[1, 2, 3, 4]), 4);
        // Drain half — now start pointer is at offset 4
        assert_eq!(consumer.read_to_slice(&mut out), 4);
        assert_eq!(&out[..4], &[1, 2, 3, 4]);

        // Write 6 bytes — wraps around the end of the buffer
        // But write_from_slice only writes contiguous chunk up to end
        let written = producer.write_from_slice(&[5, 6, 7, 8, 9, 10]);
        assert_eq!(written, 4); // 8 - 4 = 4 slots until end
        assert_eq!(producer.len(), 4);

        // Write the rest into the wrapped region
        let written2 = producer.write_from_slice(&[9, 10]);
        assert_eq!(written2, 2);
        assert_eq!(producer.len(), 6);

        // Read all 6 — should get [5,6,7,8] then [9,10]
        let n = consumer.read_to_slice(&mut out);
        assert_eq!(n, 4); // first contiguous read
        assert_eq!(&out[..4], &[5, 6, 7, 8]);

        let n2 = consumer.read_to_slice(&mut out);
        assert_eq!(n2, 2);
        assert_eq!(&out[..2], &[9, 10]);
    }

    #[test]
    fn test_spsc_single_byte_ops() {
        let (mut producer, mut consumer) = spsc_buffer(4);
        let mut out = [0u8; 1];

        for i in 0..10u8 {
            assert_eq!(producer.write_from_slice(&[i]), 1);
            assert_eq!(consumer.read_to_slice(&mut out), 1);
            assert_eq!(out[0], i);
        }
    }

    #[test]
    fn test_spsc_read_trait() {
        let (mut producer, mut consumer) = spsc_buffer(16);
        producer.write_from_slice(b"hello");

        let mut buf = [0u8; 16];
        let n = consumer.read(&mut buf).unwrap();
        assert_eq!(n, 5);
        assert_eq!(&buf[..5], b"hello");
    }

    #[test]
    fn test_spsc_write_trait() {
        let (mut producer, mut consumer) = spsc_buffer(16);
        let n = producer.write(b"world").unwrap();
        assert_eq!(n, 5);

        let mut buf = [0u8; 16];
        assert_eq!(consumer.read_to_slice(&mut buf), 5);
        assert_eq!(&buf[..5], b"world");
    }

    #[test]
    fn test_spsc_size_one() {
        let (mut producer, mut consumer) = spsc_buffer(1);
        assert_eq!(producer.write_from_slice(&[42]), 1);
        assert!(producer.is_full());
        assert_eq!(producer.write_from_slice(&[99]), 0);

        let mut out = [0u8; 1];
        assert_eq!(consumer.read_to_slice(&mut out), 1);
        assert_eq!(out[0], 42);
        assert!(consumer.is_empty());
    }

    #[test]
    fn test_spsc_partial_read_into_small_buffer() {
        let (mut producer, mut consumer) = spsc_buffer(16);
        producer.write_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);

        let mut small = [0u8; 3];
        assert_eq!(consumer.read_to_slice(&mut small), 3);
        assert_eq!(&small, &[1, 2, 3]);
        assert_eq!(consumer.len(), 5);
    }

    #[test]
    fn test_spsc_fill_drain_repeat() {
        let (mut producer, mut consumer) = spsc_buffer(4);
        let mut out = [0u8; 4];

        for round in 0..5u8 {
            let data = [round; 4];
            assert_eq!(producer.write_from_slice(&data), 4);
            assert!(producer.is_full());

            assert_eq!(consumer.read_to_slice(&mut out), 4);
            assert_eq!(out, data);
            assert!(consumer.is_empty());
        }
    }
}
