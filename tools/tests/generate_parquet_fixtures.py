#!/usr/bin/env python3
"""Regenerate independent Parquet fixtures (development-only PyArrow dependency).

--large DIR also writes performance inputs with a single large row group and
page indexes. These generated large inputs are deliberately not committed.
"""
import argparse
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

parser = argparse.ArgumentParser()
parser.add_argument('--large', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2] / 'backend/tests/fixtures/parquet'
root.mkdir(parents=True, exist_ok=True)
table = pa.table({
    'id': pa.array([1, -2, 3, 4, 5, 6, 7, 8], type=pa.int64()),
    'name': ['Ada', 'Ålan', None, 'comma,quote"', 'line\nfeed', '', '東京', 'last'],
    'score': [1.25, -2.5, None, 0., 5.5, 6., 7.25, 8.5],
    'flag': [True, False, None, True, False, True, False, True],
    'day': pa.array([date(1969, 12, 31), date(2026, 10, 4), None,
                     date(2000, 2, 29), date(1970, 1, 1), date(2020, 2, 29),
                     date(1900, 3, 1), date(2100, 3, 1)], type=pa.date32()),
    'stamp': pa.array([datetime(2026, 10, 4, 12, 34, 56, 123456,
                               tzinfo=timezone.utc)] * 8,
                      type=pa.timestamp('us', tz='UTC')),
    'amount': pa.array([Decimal('123456789012.3456'), Decimal('-0.0012'), None,
                       Decimal('0'), Decimal('5.5'), Decimal('6'),
                       Decimal('7.25'), Decimal('8.5')], type=pa.decimal128(20, 4)),
    'unsigned': pa.array([2**64 - 1, 0, 1, 2, 3, 4, 5, 6], type=pa.uint64()),
})
for codec in ('none', 'snappy', 'zstd', 'gzip', 'brotli', 'lz4'):
    for version in (1, 2):
        pq.write_table(table, root / f'{codec}-v{version}.parquet',
                       compression=codec, row_group_size=4, data_page_size=512,
                       data_page_version=f'{version}.0', write_page_checksum=True)
pq.write_table(pa.table({'x': pa.array([], type=pa.int64())}), root / 'empty.parquet')
pq.write_table(pa.table({'x': [[1, 2], [3]]}), root / 'nested.parquet')
logical = pa.table({'money': pa.array([Decimal('-0.12'), Decimal('1234.56')], type=pa.decimal128(8, 2)),
                    'time': pa.array([12 * 3600 * 1000000 + 34 * 60 * 1000000 + 56789000, 0], type=pa.time64('us'))})
for version in (1, 2):
    pq.write_table(logical, root / f'logical-v{version}.parquet',
                   data_page_version=f'{version}.0', compression='snappy',
                   store_decimal_as_integer=True, write_page_checksum=True)
many = pa.table({'id': pa.array(range(5000), type=pa.int64()),
                 'name': ['last' if i == 4999 else 'row' for i in range(5000)]})
pq.write_table(many, root / 'blocks.parquet', row_group_size=5000,
               data_page_size=1024, compression='snappy', write_page_index=True)
if args.large:
    args.large.mkdir(parents=True, exist_ok=True)
    # Pages are small; the 10M-row group must never be eagerly decoded on open.
    n = 10_000_000
    values = pa.array(range(n), type=pa.int64())
    big = pa.table({f'column_{i}': values for i in range(16)})
    for codec in ('snappy', 'zstd'):
        pq.write_table(big, args.large / f'large-{codec}.parquet',
                       compression=codec, row_group_size=n, data_page_size=65536,
                       use_dictionary=False, write_page_index=True,
                       write_page_checksum=True)
    wide = pa.table({f'column_{i}': values.slice(0, 10000) for i in range(512)})
    pq.write_table(wide, args.large / 'wide.parquet', compression='snappy',
                   use_dictionary=False, data_page_size=65536)
    print('Generated large Parquet benchmark inputs in', args.large)
