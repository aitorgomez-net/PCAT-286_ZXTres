"""Reject changed architectural work/state independently of code prefetch."""
import unittest
from compare_at_memory_perf import compare

class MemoryComparisonTests(unittest.TestCase):
    def setUp(self):
        self.before=dict(cycles=100,retired=8,data_reads=7,other_reads=0,writes=5,
            sdram_writes=5,gpr='0123456789abcdef'*2,flags='0002',cs='f000',ip='0111',
            memory='00abcdef',code_reads=10)
        self.after=dict(self.before,cycles=70,code_reads=12)
    def test_prefetch_variation_retains_all_work(self):
        self.assertGreater(compare(self.before,self.after,True),1)
    def test_each_architectural_field_is_required(self):
        for key in ('retired','data_reads','other_reads','writes','gpr','flags','cs','ip','memory'):
            with self.subTest(key=key):
                changed=dict(self.after)
                changed[key]=changed[key]+1 if isinstance(changed[key],int) else 'changed'
                with self.assertRaises(AssertionError): compare(self.before,changed)
    def test_physical_stores_when_width_matches(self):
        with self.assertRaises(AssertionError):
            compare(self.before,dict(self.after,sdram_writes=6),True)
    def test_completion_must_be_faster(self):
        for cycles in (0,100,101):
            with self.assertRaises(AssertionError): compare(self.before,dict(self.after,cycles=cycles))

if __name__=='__main__': unittest.main()
