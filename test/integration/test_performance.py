"""
Performance benchmarks for the unified bridge variable system.
"""

import time
import statistics
from typing import List
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
import random

# Add the Python bridge to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../priv/python'))

from snakepit_bridge import SessionContext, VariableType
from .test_infrastructure import test_server, test_session, TestMetrics


class BenchmarkSuite:
    """Performance benchmark suite."""
    
    def __init__(self, session: SessionContext):
        self.session = session
        self.results = {}
    
    def run_all(self):
        """Run all benchmarks."""
        print("\n=== Running Performance Benchmarks ===")
        
        self.benchmark_single_operations()
        self.benchmark_batch_operations()
        self.benchmark_cache_effectiveness()
        self.benchmark_concurrent_access()
        
        self.print_results()
        self.save_results()
    
    def benchmark_single_operations(self):
        """Benchmark individual operations."""
        print("\nBenchmarking single operations...")
        
        # Register
        times = []
        for i in range(100):
            start = time.time()
            self.session.register_variable(f'bench_reg_{i}', VariableType.INTEGER, i)
            times.append(time.time() - start)
        self.results['register'] = times
        
        # Get (uncached)
        self.session.clear_cache()
        times = []
        for i in range(100):
            start = time.time()
            _ = self.session.get_variable(f'bench_reg_{i}')
            times.append(time.time() - start)
        self.results['get_uncached'] = times
        
        # Get (cached)
        times = []
        for i in range(100):
            start = time.time()
            _ = self.session.get_variable(f'bench_reg_{i}')
            times.append(time.time() - start)
        self.results['get_cached'] = times
        
        # Update
        times = []
        for i in range(100):
            start = time.time()
            self.session.update_variable(f'bench_reg_{i}', i * 2)
            times.append(time.time() - start)
        self.results['update'] = times
    
    def benchmark_batch_operations(self):
        """Benchmark batch vs individual operations."""
        print("\nBenchmarking batch operations...")
        
        # Setup variables
        for i in range(100):
            self.session.register_variable(f'batch_{i}', VariableType.INTEGER, 0)
        
        # Individual updates
        start = time.time()
        for i in range(100):
            self.session.update_variable(f'batch_{i}', i)
        individual_time = time.time() - start
        
        # Batch update
        updates = {f'batch_{i}': i * 2 for i in range(100)}
        start = time.time()
        self.session.update_variables(updates)
        batch_time = time.time() - start
        
        self.results['individual_updates'] = [individual_time]
        self.results['batch_updates'] = [batch_time]
        
        print(f"Individual updates: {individual_time:.3f}s")
        print(f"Batch updates: {batch_time:.3f}s")
        if batch_time > 0:
            print(f"Speedup: {individual_time/batch_time:.1f}x")
    
    def benchmark_cache_effectiveness(self):
        """Measure cache hit rate and performance."""
        print("\nBenchmarking cache effectiveness...")
        
        # Create variables with different access patterns
        for i in range(20):
            self.session.register_variable(f'cache_test_{i}', VariableType.FLOAT, i * 0.1)
        
        # Simulate realistic access pattern
        access_pattern = []
        # 80% of accesses to 20% of variables (hotspot)
        hot_vars = [f'cache_test_{i}' for i in range(4)]
        cold_vars = [f'cache_test_{i}' for i in range(4, 20)]
        
        for _ in range(1000):
            if random.random() < 0.8:
                access_pattern.append(random.choice(hot_vars))
            else:
                access_pattern.append(random.choice(cold_vars))
        
        # Clear cache and measure
        self.session.clear_cache()
        times = []
        
        for var_name in access_pattern:
            start = time.time()
            _ = self.session[var_name]
            times.append(time.time() - start)
        
        self.results['realistic_access'] = times
        
        # Calculate cache effectiveness
        avg_first_100 = statistics.mean(times[:100])
        avg_last_100 = statistics.mean(times[-100:])
        print(f"Average access time first 100: {avg_first_100*1000:.2f}ms")
        print(f"Average access time last 100: {avg_last_100*1000:.2f}ms")
        if avg_last_100 > 0:
            print(f"Cache improvement: {avg_first_100/avg_last_100:.1f}x")
    
    def benchmark_concurrent_access(self):
        """Benchmark concurrent access patterns."""
        print("\nBenchmarking concurrent access...")
        
        # Setup shared variables
        for i in range(10):
            self.session.register_variable(f'concurrent_{i}', VariableType.INTEGER, 0)
        
        def worker_task(worker_id: int, iterations: int):
            times = []
            for i in range(iterations):
                var_name = f'concurrent_{i % 10}'
                start = time.time()
                value = self.session[var_name]
                self.session[var_name] = value + 1
                times.append(time.time() - start)
            return times
        
        # Test with different worker counts
        for workers in [1, 5, 10, 20]:
            all_times = []
            
            with ThreadPoolExecutor(max_workers=workers) as executor:
                futures = []
                for i in range(workers):
                    future = executor.submit(worker_task, i, 50)
                    futures.append(future)
                
                for future in as_completed(futures):
                    all_times.extend(future.result())
            
            avg_time = statistics.mean(all_times)
            self.results[f'concurrent_{workers}_workers'] = all_times
            print(f"{workers} workers: {avg_time*1000:.2f}ms average")
    
    def print_results(self):
        """Print benchmark results."""
        print("\n=== Benchmark Results ===")
        
        for name, times in self.results.items():
            if times:
                avg = statistics.mean(times)
                median = statistics.median(times)
                stdev = statistics.stdev(times) if len(times) > 1 else 0
                
                print(f"\n{name}:")
                print(f"  Average: {avg*1000:.2f}ms")
                print(f"  Median: {median*1000:.2f}ms")
                print(f"  Std Dev: {stdev*1000:.2f}ms")
                print(f"  Min: {min(times)*1000:.2f}ms")
                print(f"  Max: {max(times)*1000:.2f}ms")
                print(f"  Samples: {len(times)}")
    
    def save_results(self):
        """Save results to file for analysis."""
        import json
        
        # Convert results to serializable format
        serializable_results = {}
        for name, times in self.results.items():
            serializable_results[name] = {
                'times_ms': [t * 1000 for t in times],
                'average_ms': statistics.mean(times) * 1000 if times else 0,
                'median_ms': statistics.median(times) * 1000 if times else 0,
                'min_ms': min(times) * 1000 if times else 0,
                'max_ms': max(times) * 1000 if times else 0,
                'samples': len(times)
            }
        
        with open('benchmark_results.json', 'w') as f:
            json.dump(serializable_results, f, indent=2)
        print("\nBenchmark results saved to benchmark_results.json")
    
    def plot_results(self):
        """Generate performance plots if matplotlib is available."""
        try:
            import matplotlib
            matplotlib.use('Agg')  # Use non-interactive backend
            import matplotlib.pyplot as plt
            
            fig, axes = plt.subplots(2, 2, figsize=(12, 10))
            fig.suptitle('Variable System Performance Benchmarks')
            
            # Single operations comparison
            ax = axes[0, 0]
            ops = ['register', 'get_uncached', 'get_cached', 'update']
            avg_times = []
            for op in ops:
                if op in self.results and self.results[op]:
                    avg_times.append(statistics.mean(self.results[op]) * 1000)
                else:
                    avg_times.append(0)
            ax.bar(ops, avg_times)
            ax.set_ylabel('Time (ms)')
            ax.set_title('Single Operation Performance')
            
            # Cache hit distribution
            ax = axes[0, 1]
            if 'realistic_access' in self.results:
                times_ms = [t * 1000 for t in self.results['realistic_access']]
                ax.hist(times_ms, bins=50, alpha=0.7)
                ax.set_xlabel('Access Time (ms)')
                ax.set_ylabel('Frequency')
                ax.set_title('Access Time Distribution')
            
            # Batch vs Individual
            ax = axes[1, 0]
            if 'individual_updates' in self.results and 'batch_updates' in self.results:
                methods = ['Individual', 'Batch']
                times = [
                    self.results['individual_updates'][0] * 1000,
                    self.results['batch_updates'][0] * 1000
                ]
                ax.bar(methods, times)
                ax.set_ylabel('Time (ms)')
                ax.set_title('Batch vs Individual Updates (100 vars)')
            
            # Concurrent scalability
            ax = axes[1, 1]
            worker_counts = []
            avg_times = []
            for workers in [1, 5, 10, 20]:
                key = f'concurrent_{workers}_workers'
                if key in self.results:
                    worker_counts.append(workers)
                    avg_times.append(statistics.mean(self.results[key]) * 1000)
            
            if worker_counts:
                ax.plot(worker_counts, avg_times, 'o-')
                ax.set_xlabel('Number of Workers')
                ax.set_ylabel('Avg Operation Time (ms)')
                ax.set_title('Concurrent Access Scalability')
            
            plt.tight_layout()
            plt.savefig('variable_benchmarks.png')
            print("Benchmark plots saved to variable_benchmarks.png")
        except ImportError:
            print("\nMatplotlib not available, skipping plots")


def test_performance_suite():
    """Run the full performance benchmark suite."""
    with test_server() as server:
        with test_session(server) as session:
            suite = BenchmarkSuite(session)
            suite.run_all()


def main():
    """Run benchmarks standalone."""
    print("Starting performance benchmark suite...")
    print("This will take a few minutes to complete.")
    
    try:
        test_performance_suite()
    except KeyboardInterrupt:
        print("\nBenchmark interrupted by user")
    except Exception as e:
        print(f"\nError running benchmarks: {e}")
        import traceback
        traceback.print_exc()


if __name__ == '__main__':
    main()