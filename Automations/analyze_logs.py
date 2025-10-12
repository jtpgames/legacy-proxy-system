#!/usr/bin/env python

"""
Locust Log Analyzer

Analyzes locust log files to extract response times and error counts,
creating bar charts for visualization with enhanced request count display.

Features:
- Response time analysis with request count visualization
- Detailed error categorization by HTTP status and functional types
- Success rate calculation and statistics
- PDF chart generation with experiment type detection
"""

import re
import typer
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Tuple
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from dataclasses import dataclass
from datetime import datetime

@dataclass
class FileData:
    """Data class to store parsed data from a single log file."""
    file_path: Path
    response_times: Dict[str, List[float]]
    error_stats: 'ErrorStats'
    file_label: str  # Human-readable label for the file
    # For scatter plot functionality
    response_timestamps: Dict[str, List[float]] = None  # Relative time in seconds from start
    error_timestamps: List[float] = None  # Timestamps of all errors
    start_time: float = None  # Start timestamp of the log file

@dataclass
class ErrorStats:
    """Data class to track different types of errors."""
    # HTTP Status Code Errors
    http_500_errors: int = 0  # Internal Server Error
    http_502_errors: int = 0  # Bad Gateway
    http_503_errors: int = 0  # Service Unavailable
    
    # Functional Errors
    login_errors: int = 0     # Login related errors
    logout_errors: int = 0    # Logout related errors
    profile_errors: int = 0   # Profile access errors
    product_errors: int = 0   # Product access/cart errors
    category_errors: int = 0  # Category browsing errors
    page_load_errors: int = 0 # Page loading errors
    
    # Legacy error types (for backward compatibility)
    timeout_errors: int = 0
    unknown_errors: int = 0
    connection_errors: int = 0
    other_errors: int = 0
    
    @property
    def total_errors(self) -> int:
        return (self.http_500_errors + self.http_502_errors + self.http_503_errors +
                self.login_errors + self.logout_errors + self.profile_errors +
                self.product_errors + self.category_errors + self.page_load_errors +
                self.timeout_errors + self.unknown_errors + self.connection_errors + self.other_errors)
    
    @property
    def total_http_errors(self) -> int:
        return self.http_500_errors + self.http_502_errors + self.http_503_errors
    
    @property 
    def total_functional_errors(self) -> int:
        return (self.login_errors + self.logout_errors + self.profile_errors +
                self.product_errors + self.category_errors + self.page_load_errors)
    
    def to_dict(self) -> Dict[str, int]:
        return {
            'HTTP 503 (Service Unavailable)': self.http_503_errors,
            'HTTP 502 (Bad Gateway)': self.http_502_errors,
            'HTTP 500 (Internal Server)': self.http_500_errors,
            'Login Errors': self.login_errors,
            'Logout Errors': self.logout_errors,
            'Profile Access Errors': self.profile_errors,
            'Product/Cart Errors': self.product_errors,
            'Category Browse Errors': self.category_errors,
            'Page Load Errors': self.page_load_errors,
            'Timeout Errors': self.timeout_errors,
            'Unknown/Empty Errors': self.unknown_errors,
            'Connection Errors': self.connection_errors,
            'Other Errors': self.other_errors
        }

app = typer.Typer()

def parse_multiple_log_files(log_files: List[Path]) -> List[FileData]:
    """
    Parse multiple log files and return a list of FileData objects.
    
    Args:
        log_files: List of Path objects pointing to log files
        
    Returns:
        List of FileData objects containing parsed data from each file
    """
    file_data_list = []
    used_labels = {}  # Track how many times each label has been used
    
    for log_file in log_files:
        typer.echo(f"Parsing {log_file.name}...")
        response_times, error_stats, response_timestamps, error_timestamps, start_time = parse_log_file(log_file)
        
        # Create a human-readable label using experiment type
        try:
            experiment_type = log_file.parent.parent.name
            base_file_label = experiment_type
        except (AttributeError, IndexError):
            # Fallback to filename if we can't determine experiment type
            base_file_label = log_file.stem
        
        # Handle duplicate labels by adding numeric postfixes
        if base_file_label in used_labels:
            used_labels[base_file_label] += 1
            file_label = f"{base_file_label}-{used_labels[base_file_label]}"
        else:
            used_labels[base_file_label] = 0
            file_label = base_file_label
        
        file_data = FileData(
            file_path=log_file,
            response_times=response_times,
            error_stats=error_stats,
            file_label=file_label,
            response_timestamps=response_timestamps,
            error_timestamps=error_timestamps,
            start_time=start_time
        )
        file_data_list.append(file_data)
    
    return file_data_list

def parse_log_file(file_path: Path) -> Tuple[Dict[str, List[float]], ErrorStats, Dict[str, List[float]], List[float], float]:
    """
    Parse the locust log file to extract response times and categorized error counts.
    
    Returns:
        Tuple of (request_types_with_response_times, error_statistics, 
                 response_timestamps, error_timestamps, start_time)
    """
    response_times = defaultdict(list)
    response_timestamps = defaultdict(list)
    error_timestamps = []
    error_stats = ErrorStats()
    start_time = None
    
    # Pattern to match response time lines in INFO logs: (METHOD endpoint) Response time X ms
    response_pattern = re.compile(r'/INFO/root:\s+\(([A-Z]+\s+\w+)\)\s+Response\s+time\s+(\d+)\s+ms')
    
    # Pattern to match error lines and capture the error message
    error_pattern = re.compile(r'ERROR/root: user\d+: (.*)$')
    
    # Pattern to extract timestamp from log line
    timestamp_pattern = re.compile(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\]')
   
    warmup_pattern = re.compile(r'Warm-Up finished.*Regular load profile starts', re.IGNORECASE)
    warmup_finished = False
    
    def parse_timestamp(timestamp_str: str) -> float:
        """Parse timestamp string to seconds since epoch."""
        try:
            # Parse format like "2025-10-03 18:50:10,744"
            dt = datetime.strptime(timestamp_str, "%Y-%m-%d %H:%M:%S,%f")
            return dt.timestamp()
        except ValueError:
            return None
    
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            for line_num, line in enumerate(file, 1):
                if not warmup_finished:
                    if warmup_pattern.search(line):
                        warmup_finished = True
                    continue

                # Extract timestamp from every line
                timestamp_match = timestamp_pattern.search(line)
                current_timestamp = None
                if timestamp_match:
                    current_timestamp = parse_timestamp(timestamp_match.group(1))
                    if start_time is None:
                        start_time = current_timestamp

                # Check for response time entries
                response_match = response_pattern.search(line)
                if response_match:
                    request_type = response_match.group(1)
                    response_time = float(response_match.group(2))
                    response_times[request_type].append(response_time)
                    
                    # Store relative timestamp for scatter plot
                    if current_timestamp and start_time:
                        relative_time = current_timestamp - start_time
                        response_timestamps[request_type].append(relative_time)
                
                # Check for error entries
                else:
                    error_match = error_pattern.search(line)
                    if error_match:
                        error_message = error_match.group(1).strip()
                        
                        # Store error timestamp
                        if current_timestamp and start_time:
                            relative_time = current_timestamp - start_time
                            error_timestamps.append(relative_time)
                        
                        # Categorize the error based on the message
                        error_type = "Unknown"
                        
                        if error_message == "":
                            error_stats.unknown_errors += 1
                            error_type = "Unknown/Empty"
                        elif "timed out" in error_message.lower():
                            error_stats.timeout_errors += 1
                            error_type = "Timeout"
                        elif any(conn_keyword in error_message.lower() for conn_keyword in 
                                ["connection", "connect", "refused", "reset", "closed"]):
                            error_stats.connection_errors += 1
                            error_type = "Connection"
                        # HTTP Status Code categorization
                        elif "status 500" in error_message or "status: 500" in error_message:
                            error_stats.http_500_errors += 1
                            error_type = "HTTP 500"
                        elif "status 502" in error_message or "status: 502" in error_message:
                            error_stats.http_502_errors += 1
                            error_type = "HTTP 502"
                        elif "status 503" in error_message or "status: 503" in error_message:
                            error_stats.http_503_errors += 1
                            error_type = "HTTP 503"
                        # Functional error categorization
                        elif "login" in error_message.lower() and "username" in error_message.lower():
                            error_stats.login_errors += 1
                            error_type = "Login"
                        elif "log out" in error_message.lower() or "logout" in error_message.lower():
                            error_stats.logout_errors += 1
                            error_type = "Logout"
                        elif "profile" in error_message.lower():
                            error_stats.profile_errors += 1
                            error_type = "Profile"
                        elif "product" in error_message.lower() or "cart" in error_message.lower():
                            error_stats.product_errors += 1
                            error_type = "Product/Cart"
                        elif "category" in error_message.lower():
                            error_stats.category_errors += 1
                            error_type = "Category"
                        elif "load" in error_message.lower() and ("page" in error_message.lower() or "landing" in error_message.lower()):
                            error_stats.page_load_errors += 1
                            error_type = "Page Load"
                        else:
                            error_stats.other_errors += 1
                            error_type = "Other"
                        
                        # typer.echo(f"Found {error_type} error at line {line_num}: {line.strip()}")
    
    except FileNotFoundError:
        typer.echo(f"Error: File '{file_path}' not found.", err=True)
        raise typer.Exit(1)
    except Exception as e:
        typer.echo(f"Error reading file: {e}", err=True)
        raise typer.Exit(1)
    
    return dict(response_times), error_stats, dict(response_timestamps), error_timestamps, start_time


def calculate_multi_file_statistics(file_data_list: List[FileData]) -> pd.DataFrame:
    """Calculate statistics for multiple files, keeping file information."""
    all_stats = []
    
    for file_data in file_data_list:
        for request_type, times in file_data.response_times.items():
            if times:  # Only process if there are response times
                sorted_times = sorted(times)
                n = len(sorted_times)
                
                # Calculate median
                if n % 2 == 0:
                    median_time = (sorted_times[n//2 - 1] + sorted_times[n//2]) / 2
                else:
                    median_time = sorted_times[n//2]
                
                all_stats.append({
                    'Request Type': request_type,
                    'File': file_data.file_label,
                    'Average Response Time (ms)': sum(times) / len(times),
                    'Median Response Time (ms)': median_time,
                    'Min Response Time (ms)': min(times),
                    'Max Response Time (ms)': max(times),
                    'Count': len(times)
                })
    
    return pd.DataFrame(all_stats).sort_values(['Request Type', 'File'])


def create_multi_file_bar_chart(file_data_list: List[FileData], output_dir: Path, 
                                omit_request_count_per_bar_labels: bool = False,
                                simple_title: bool = False,
                                publication_ready: bool = False,
                                export_svg: bool = False,
                                metric_type: str = "average"):
    """Create and save bar charts for multiple files using textures to distinguish files."""
    
    # Check if there are any errors across all files
    total_errors_across_files = sum(file_data.error_stats.total_errors for file_data in file_data_list)
    has_errors = total_errors_across_files > 0
    
    # Set publication-ready styling
    if publication_ready:
        plt.rcParams.update({
            'font.size': 16,
            'axes.titlesize': 16,
            'axes.labelsize': 18,
            'xtick.labelsize': 16,
            'ytick.labelsize': 16,
            'legend.fontsize': 14,
            'font.family': 'serif',
            'font.serif': ['Times', 'Times New Roman', 'DejaVu Serif'],
            'mathtext.fontset': 'dejavuserif',
            # LaTeX text rendering for crisp output
            'text.usetex': True,
            'text.latex.preamble': r'\usepackage{times}',
            'pdf.fonttype': 42,     # TrueType fonts (not bitmap)
            'ps.fonttype': 42,      # TrueType fonts (not bitmap)
            'svg.fonttype': 'none', # Keep text as text in SVG
            'axes.unicode_minus': False,  # Use LaTeX minus sign
        })
        # Adjust figure size based on whether we have errors
        if has_errors:
            figsize = (12, 8)  # Standard two-subplot size
        else:
            figsize = (12, 5)  # Smaller height for single subplot
    else:
        if has_errors:
            figsize = (14, 10)  # Standard two-subplot size
        else:
            figsize = (14, 6)   # Smaller height for single subplot
    
    # Create figure with appropriate subplot layout
    if has_errors:
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=figsize)
    else:
        fig, ax1 = plt.subplots(1, 1, figsize=figsize)
    
    # Define hatching patterns for different files - improved for better visibility
    hatch_patterns = ['', '///', '\\\\', '|||', '---', '+++', 'xxx', 'ooo']
    
    # Collect all request types across all files
    all_request_types = set()
    for file_data in file_data_list:
        all_request_types.update(file_data.response_times.keys())
    all_request_types = sorted(all_request_types)
    
    # Plot 1: Response Times by Request Type (Multiple Files)
    if all_request_types:
        bar_width = 0.8 / len(file_data_list)  # Width of each bar group
        x_positions = np.arange(len(all_request_types))
        
        # Calculate per-file totals for title
        file_totals = []
        
        # Academic-friendly color palette (colorblind safe)
        colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd', '#8c564b', '#e377c2', '#7f7f7f']
        
        if len(file_data_list) > 8:
            # Use colormap for many categories
            colors = plt.colormaps['tab10'](np.linspace(0, 1, len(file_data_list)))

        for i, file_data in enumerate(file_data_list):
            file_response_times = []
            file_request_counts = []
            file_total_requests = 0

            color_to_use = colors[i]
            
            for request_type in all_request_types:
                if request_type in file_data.response_times and file_data.response_times[request_type]:
                    times = file_data.response_times[request_type]
                    count = len(times)
                    
                    # Calculate the selected metric
                    if metric_type.lower() == 'median':
                        sorted_times = sorted(times)
                        n = len(sorted_times)
                        if n % 2 == 0:
                            response_time_value = (sorted_times[n//2 - 1] + sorted_times[n//2]) / 2
                        else:
                            response_time_value = sorted_times[n//2]
                    else:  # average
                        response_time_value = sum(times) / len(times)
                else:
                    response_time_value = 0
                    count = 0
                
                file_response_times.append(response_time_value)
                file_request_counts.append(count)
                file_total_requests += count
            
            file_totals.append(file_total_requests)
           
            
            # Create bars for this file with specific texture
            hatch = hatch_patterns[i % len(hatch_patterns)]
            edge_width = 1.0 if publication_ready else 0.5
            alpha_val = 0.8 if publication_ready else 0.7
            bars = ax1.bar(x_positions + i * bar_width, file_response_times, 
                          bar_width, label=file_data.file_label,
                          color=color_to_use, alpha=alpha_val, hatch=hatch, 
                          edgecolor='black', linewidth=edge_width)
           
            # Add value labels on bars (omit response time labels in publication mode for cleaner appearance)
            for j, (bar, response_time, count) in enumerate(zip(bars, file_response_times, file_request_counts)):
                if response_time > 0:  # Only label non-zero bars
                    height = bar.get_height()
                    
                    # Only show response time labels if not in publication mode
                    if not publication_ready:
                        ax1.text(bar.get_x() + bar.get_width()/2., height + height*0.01,
                                f'{response_time:.0f}ms', ha='center', va='bottom', fontsize=8, fontweight='bold')
                   
                    if not omit_request_count_per_bar_labels:
                        # Add request count in the middle of the bar
                        if count > 0:
                            ax1.text(bar.get_x() + bar.get_width()/2., height/2,
                                    f'{count}', ha='center', va='center', 
                                    fontsize=6, color='black', fontweight='bold')
        
        # ax1.set_xlabel('Request Type', fontweight='bold')
        ax1.set_ylabel(f'{metric_type.title()} Response Time (ms)', fontweight='bold')
       
        if not simple_title:
            # Create title with per-file request counts
            title_parts = []
            for file_data, total in zip(file_data_list, file_totals):
                title_parts.append(f'{file_data.file_label}: {total:,}')
            title_suffix = ' | '.join(title_parts)
            title_suffix = f"\n({title_suffix})"
        else:
            title_suffix = ""
        # Place title inside the plot area instead of above
        title_text = f'{metric_type.title()} Response Times per Request Type {title_suffix}'
        ax1.text(0.02, 0.98, title_text, transform=ax1.transAxes, 
               fontweight='bold', verticalalignment='top',
               bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))
        
        ax1.set_xticks(x_positions + bar_width * (len(file_data_list) - 1) / 2)
        ax1.set_xticklabels(all_request_types, rotation=45, ha='right')
        ax1.grid(axis='y', alpha=0.3, linestyle='--', linewidth=0.5)

        # Add significant vertical headroom to accommodate legend at top of chart
        ax1.margins(y=0.5)
        
        # Horizontal legend positioned at right corner intersecting with chart border
        ncols = min(len(file_data_list), 3)  # Max 3 items per row for horizontal layout
        ax1.legend(loc='upper right', bbox_to_anchor=(1.0, 1.0), ncol=ncols, 
                  frameon=True, fancybox=True, shadow=False)
    else:
        ax1.text(0.5, 0.5, 'No response time data found', 
                ha='center', va='center', transform=ax1.transAxes)
        # Place title inside the plot area instead of above
        title_text = f'{metric_type.title()} Response Times per Request Type - Multiple Files'
        ax1.text(0.02, 0.98, title_text, transform=ax1.transAxes, 
               fontweight='bold', verticalalignment='top',
               bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))
    
    # Plot 2: Error Breakdown by Type (Per File with Textures) - Only if there are errors
    if has_errors:
        # Collect all error types across all files
        all_error_types = set()
        for file_data in file_data_list:
            error_dict = file_data.error_stats.to_dict()
            filtered_errors = {k: v for k, v in error_dict.items() if v > 0}
            all_error_types.update(filtered_errors.keys())
        
        all_error_types = sorted(all_error_types)
        
        if all_error_types:
            error_bar_width = 0.8 / len(file_data_list)  # Width of each error bar group
            error_x_positions = np.arange(len(all_error_types))
            
            # Calculate total errors per file for title
            file_error_totals = []
            
            for i, file_data in enumerate(file_data_list):
                file_error_counts = []
                
                # Get error counts for this file for each error type
                error_dict = file_data.error_stats.to_dict()
                for error_type in all_error_types:
                    count = error_dict.get(error_type, 0)
                    file_error_counts.append(count)
                
                file_error_totals.append(file_data.error_stats.total_errors)
                
                # Create bars for this file with specific texture
                hatch = hatch_patterns[i % len(hatch_patterns)]
                edge_width = 1.0 if publication_ready else 0.5
                
                # Use the same color as the response time chart for this file (consistent across both charts)
                color_to_use = colors[i]
                
                # For error bars, use the same color for each file (matching response time chart)
                bars = ax2.bar(error_x_positions + i * error_bar_width, file_error_counts, 
                              error_bar_width, label=file_data.file_label,
                              color=color_to_use, alpha=0.8, 
                              hatch=hatch, edgecolor='black', linewidth=edge_width)
                
                # Add value labels on bars (only for non-zero values, omit in publication mode)
                for j, (bar, count) in enumerate(zip(bars, file_error_counts)):
                    if count > 0 and not publication_ready:  # Only label non-zero bars and not in publication mode
                        height = bar.get_height()
                        ax2.text(bar.get_x() + bar.get_width()/2., height + height*0.01,
                                f'{count}', ha='center', va='bottom', fontsize=8, fontweight='bold')
            
            ax2.set_ylabel('Error Count', fontweight='bold')

            if not simple_title:
                # Create title with per-file error totals
                error_title_parts = []
                for file_data, total in zip(file_data_list, file_error_totals):
                    error_title_parts.append(f'{file_data.file_label}: {total}')
                error_title_suffix = ' | '.join(error_title_parts)
                error_title_suffix = f"\n({error_title_suffix})"
            else:
                error_title_suffix = ""
            # Place title inside the plot area instead of above
            error_title_text = f'Error Breakdown by Type per Error Type {error_title_suffix}'
            ax2.text(0.02, 0.98, error_title_text, transform=ax2.transAxes, 
                   fontweight='bold', verticalalignment='top',
                   bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))
            
            ax2.set_xticks(error_x_positions + error_bar_width * (len(file_data_list) - 1) / 2)
            ax2.set_xticklabels(all_error_types, rotation=45, ha='right')
            ax2.grid(axis='y', alpha=0.3, linestyle='--', linewidth=0.5)
            
            # Add significant vertical headroom to accommodate legend at top of chart
            ax2.margins(y=0.5)

            # Horizontal legend positioned at right corner intersecting with chart border (consistent with response time chart)
            ncols = min(len(file_data_list), 3)  # Max 3 items per row for horizontal layout
            ax2.legend(loc='upper right', bbox_to_anchor=(1.0, 1.0), ncol=ncols, 
                      frameon=True, fancybox=True, shadow=False)
    
    # Optimize spacing between subplots for better readability (legends now within chart area)
    if has_errors:
        if publication_ready:
            plt.subplots_adjust(hspace=0.6)  # Space for publication layout
            plt.tight_layout(pad=1.5)
        else:
            plt.subplots_adjust(hspace=0.5)  # Standard space between subplots
            plt.tight_layout(pad=1.0)
    else:
        # Single subplot, just use tight_layout
        if publication_ready:
            plt.tight_layout(pad=1.5)
        else:
            plt.tight_layout(pad=1.0)
    
    # Generate output filename for multiple files
    if len(file_data_list) == 1:
        output_filename = f'{file_data_list[0].file_label}_locust_analysis_results.pdf'
    else:
        file_labels = '_vs_'.join([fd.file_label for fd in file_data_list[:3]])  # Limit to first 3 for filename
        if len(file_data_list) > 3:
            file_labels += '_and_more'
        output_filename = f'multi_file_comparison_{file_labels}.pdf'
    
    output_file = output_dir / output_filename
    
    # Save with publication-quality settings optimized for small two-column figures
    if publication_ready:
        plt.savefig(output_file, format='pdf', 
                   bbox_inches='tight',    # Remove extra whitespace
                   dpi=600,               # Higher DPI for small figures (better text clarity)
                   facecolor='white',     # Clean background
                   edgecolor='none',      # No border
                   pad_inches=0.02,       # Minimal padding for compact layout
                   transparent=False)     # Solid background for print
        
        # Also export SVG for LaTeX if requested
        if export_svg:
            svg_file = output_file.with_suffix('.svg')
            plt.savefig(svg_file, format='svg', bbox_inches='tight',
                       facecolor='white', edgecolor='none', pad_inches=0.02)
            typer.echo(f"SVG version saved to: {svg_file}")
    else:
        plt.savefig(output_file, format='pdf', bbox_inches='tight')
    
    typer.echo(f"Multi-file chart saved to: {output_file}")
    
    # Show the plot
    # plt.show()


def _get_subplot_position_info(subplot_index: int, rows: int, cols: int) -> dict:
    """Helper function to determine position of subplot in grid."""
    row = subplot_index // cols
    col = subplot_index % cols
    
    return {
        'row': row,
        'col': col,
        'is_top_row': row == 0,
        'is_bottom_row': row == rows - 1,
        'is_left_col': col == 0,
        'is_right_col': col == cols - 1
    }


def create_scatter_plot(file_data_list: List[FileData], output_dir: Path,
                        publication_ready: bool = False,
                        export_svg: bool = False):
    """Create and save scatter/line plots for response times over relative time.
    
    Optimizes subplot axes by hiding:
    - X-axis labels and ticks for plots in the top rows
    - Y-axis labels and ticks for plots in the rightmost columns
    """
   
    # Set publication-ready styling
    if publication_ready:
        plt.rcParams.update({
            'font.size': 18,
            'axes.titlesize': 18,
            'axes.labelsize': 18,
            'xtick.labelsize': 16,
            'ytick.labelsize': 16,
            'legend.fontsize': 12,
            'font.family': 'serif',
            'font.serif': ['Times', 'Times New Roman', 'DejaVu Serif'],
            'mathtext.fontset': 'dejavuserif',
            'text.usetex': True,
            'text.latex.preamble': r'\usepackage{times}',
            'pdf.fonttype': 42,
            'ps.fonttype': 42,
            'svg.fonttype': 'none',
            'axes.unicode_minus': False,
        })
    
    # Calculate subplot layout based on number of files
    num_files = len(file_data_list)
    if num_files == 1:
        rows, cols = 1, 1
        figsize = (12, 8) if publication_ready else (14, 10)
    elif num_files == 2:
        rows, cols = 1, 2
        figsize = (12, 5) if publication_ready else (16, 8)
    elif num_files <= 4:
        rows, cols = 2, 2
        figsize = (12, 8) if publication_ready else (16, 12)
    elif num_files <= 6:
        rows, cols = 2, 3
        figsize = (15, 8) if publication_ready else (18, 12)
    else:
        rows, cols = 3, 3
        figsize = (15, 10) if publication_ready else (18, 15)
    
    fig, axes = plt.subplots(rows, cols, figsize=figsize)
    
    # Handle single subplot case
    if num_files == 1:
        axes = [axes]
    elif rows == 1 or cols == 1:
        # For single row or column, axes is already 1D
        pass
    else:
        # Flatten axes for easy indexing
        axes = axes.flatten()
    
    # Colors for different request types within each subplot
    request_colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#9467bd', '#8c564b', '#e377c2']
    
    # Find global y-axis range for consistent scaling
    global_max_time = 0
    for file_data in file_data_list:
        if file_data.response_times:
            for times in file_data.response_times.values():
                if times:
                    global_max_time = max(global_max_time, max(times))
    
    # Plot each file in its own subplot
    for i, file_data in enumerate(file_data_list):
        if i >= len(axes):
            break
            
        ax = axes[i]
        
        # Get position information for this subplot
        pos_info = _get_subplot_position_info(i, rows, cols)
        
        if not file_data.response_timestamps:
            ax.text(0.5, 0.5, 'No data available', ha='center', va='center', 
                   transform=ax.transAxes)
            # Place title inside the plot area instead of above
            ax.text(0.02, 0.98, file_data.file_label, transform=ax.transAxes, 
                   fontweight='bold', verticalalignment='top',
                   bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))
            
            # Apply axis hiding logic even for empty plots
            if not pos_info['is_bottom_row']:
                ax.tick_params(axis='x', which='both', bottom=False, top=False, labelbottom=False)
            if not pos_info['is_left_col']:
                ax.tick_params(axis='y', which='both', left=False, right=False, labelleft=False)
            
            continue
        
        # Plot each request type with different colors
        request_type_index = 0
        legend_elements = []
        
        for request_type, timestamps in file_data.response_timestamps.items():
            if request_type == "ERROR":
                continue  # Handle errors separately
                
            if request_type in file_data.response_times:
                response_times = file_data.response_times[request_type]
                min_len = min(len(timestamps), len(response_times))
                
                if min_len > 0:
                    color = request_colors[request_type_index % len(request_colors)]
                    scatter = ax.scatter(timestamps[:min_len], response_times[:min_len], 
                                       alpha=0.7, s=15, color=color, marker='o')
                    legend_elements.append((scatter, request_type))
                    request_type_index += 1
        
        # Plot errors as red X markers
        if file_data.error_timestamps:
            # Use a high value for error visualization
            error_response_times = [global_max_time * 1.1] * len(file_data.error_timestamps)
            # error_response_times = [0] * len(file_data.error_timestamps)
            error_scatter = ax.scatter(file_data.error_timestamps, error_response_times, 
                                     color='red', marker='x', s=30, alpha=0.8)
            legend_elements.append((error_scatter, 'Errors'))
        
        # Formatting for each subplot with optimized axis labels
        # Only show x-axis labels for bottom row
        if pos_info['is_bottom_row']:
            ax.set_xlabel('Time (seconds from start)')
        else:
            ax.tick_params(axis='x', which='both', bottom=False, top=False, labelbottom=False)
        
        # Only show y-axis labels for left column
        if pos_info['is_left_col']:
            ax.set_ylabel('Response Time (ms)')
        else:
            ax.tick_params(axis='y', which='both', left=False, right=False, labelleft=False)
        
        # Place title inside the plot area instead of above
        ax.text(0.02, 0.98, file_data.file_label, transform=ax.transAxes, 
               fontweight='bold', verticalalignment='top',
               bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))
        ax.grid(True, alpha=0.3, linestyle='--', linewidth=0.5)
        
        # Set consistent y-axis range with extra headroom for title
        if global_max_time > 0:
            ax.set_ylim(0, global_max_time * 1.35)  # Increased from 1.2 to 1.35 for title space
        
        # Add legend only if we have data
        if legend_elements:
            labels = [elem[1] for elem in legend_elements]
            handles = [elem[0] for elem in legend_elements]
            ax.legend(handles, labels, loc='upper right', frameon=True)
    
    # Hide unused subplots
    for i in range(num_files, len(axes)):
        axes[i].set_visible(False)
    
    # # Add overall title
    # if num_files > 1:
    #     fig.suptitle('Response Times Over Time - Multiple Files', fontsize=16, fontweight='bold')
    
    # Adjust layout with minimal padding between subplots
    if num_files > 1:
        # Use subplots_adjust for more precise control over spacing
        plt.subplots_adjust(hspace=0.0, wspace=0.0)  # Zero vertical and horizontal spacing
        # Apply tight_layout first, then override with subplots_adjust for final control
        plt.tight_layout(rect=[0, 0.03, 1, 0.95], pad=0.1)
        plt.subplots_adjust(hspace=0.0, wspace=0.0)  # Reapply to ensure zero spacing
    else:
        plt.tight_layout(pad=0.1)  # Minimal padding for single subplot
    
    # Generate output filename
    if len(file_data_list) == 1:
        output_filename = f'{file_data_list[0].file_label}_scatter_plot.pdf'
    else:
        file_labels = '_vs_'.join([fd.file_label for fd in file_data_list[:3]])
        if len(file_data_list) > 3:
            file_labels += '_and_more'
        output_filename = f'scatter_plot_{file_labels}.pdf'
    
    output_file = output_dir / output_filename
    
    # Save with publication-quality settings
    if publication_ready:
        plt.savefig(output_file, format='pdf', 
                   bbox_inches='tight', dpi=600, facecolor='white',
                   edgecolor='none', pad_inches=0.02, transparent=False)
        
        if export_svg:
            svg_file = output_file.with_suffix('.svg')
            plt.savefig(svg_file, format='svg', bbox_inches='tight',
                       facecolor='white', edgecolor='none', pad_inches=0.02)
            typer.echo(f"SVG version saved to: {svg_file}")
    else:
        plt.savefig(output_file, format='pdf', bbox_inches='tight')
    
    typer.echo(f"Scatter plot saved to: {output_file}")
    plt.close()


def _calculate_file_statistics(response_times: Dict[str, List[float]]) -> pd.DataFrame:
    """Calculate average and median response times for each request type (helper function)."""
    stats = []
    
    for request_type, times in response_times.items():
        if times:  # Only process if there are response times
            sorted_times = sorted(times)
            n = len(sorted_times)
            
            # Calculate median
            if n % 2 == 0:
                median_time = (sorted_times[n//2 - 1] + sorted_times[n//2]) / 2
            else:
                median_time = sorted_times[n//2]
            
            stats.append({
                'Request Type': request_type,
                'Average Response Time (ms)': sum(times) / len(times),
                'Median Response Time (ms)': median_time,
                'Min Response Time (ms)': min(times),
                'Max Response Time (ms)': max(times),
                'Count': len(times)
            })
    
    if not stats:
        return pd.DataFrame(columns=['Request Type', 'Average Response Time (ms)', 'Median Response Time (ms)', 'Min Response Time (ms)', 'Max Response Time (ms)', 'Count'])
    return pd.DataFrame(stats).sort_values('Average Response Time (ms)', ascending=False)

def print_multi_file_summary(file_data_list: List[FileData], metric_type: str = "average"):
    """Print a summary of the analysis results."""
    # Consistent header for all cases
    typer.echo("\n" + "="*80)
    typer.echo("LOCUST LOG ANALYSIS SUMMARY")
    typer.echo(f"📈 Using {metric_type.title()} Response Times for Charts")
    typer.echo("="*80)
    
    # Summary for each file
    for i, file_data in enumerate(file_data_list, 1):
        typer.echo(f"\n[{i}] FILE: {file_data.file_path.name}")
        typer.echo("-" * 60)
        
        # Calculate stats for this file
        stats_df = _calculate_file_statistics(file_data.response_times)
        
        if not stats_df.empty:
            total_requests = stats_df['Count'].sum()
            # Consistent condensed information for all cases
            typer.echo(f"Request Types: {len(stats_df)}")
            typer.echo(f"Total Requests: {total_requests:,}")
            
            # Show top 3 slowest for this file by the selected metric
            metric_column = f'{metric_type.title()} Response Time (ms)'
            sorted_stats = stats_df.sort_values(metric_column, ascending=False)
            typer.echo(f"\nTop 3 slowest request types (by {metric_type}):")
            for j, row in sorted_stats.head(3).iterrows():
                avg_time = row['Average Response Time (ms)']
                med_time = row['Median Response Time (ms)']
                selected_time = row[metric_column]
                typer.echo(f"  {j+1}. {row['Request Type']}: {selected_time:.2f}ms [{metric_type}] "
                          f"(avg: {avg_time:.2f}ms, median: {med_time:.2f}ms, count: {row['Count']})")
        else:
            typer.echo("No response time data found.")
            total_requests = 0
        
        # Error statistics for this file
        error_stats = file_data.error_stats
        
        if total_requests > 0:
            success_rate = ((total_requests - error_stats.total_errors) / total_requests * 100)
            typer.echo(f"Successful Requests: {total_requests - error_stats.total_errors:,} ({success_rate:.1f}%)")
        typer.echo(f"Total Errors: {error_stats.total_errors}")
        
        # Show consistent error summary for all cases
        if error_stats.total_errors > 0:
            if error_stats.total_http_errors > 0:
                typer.echo(f"  HTTP Errors: {error_stats.total_http_errors}")
            if error_stats.total_functional_errors > 0:
                typer.echo(f"  Functional Errors: {error_stats.total_functional_errors}")
    
    # Always show combined statistics section
    typer.echo("\n" + "="*60)
    typer.echo("COMBINED STATISTICS")
    typer.echo("="*60)
    
    # Calculate combined totals
    total_requests_all = 0
    total_errors_all = 0
    combined_request_types = set()
    
    for file_data in file_data_list:
        stats_df = _calculate_file_statistics(file_data.response_times)
        if not stats_df.empty:
            total_requests_all += stats_df['Count'].sum()
        total_errors_all += file_data.error_stats.total_errors
        combined_request_types.update(file_data.response_times.keys())
    
    typer.echo(f"Total Files Analyzed: {len(file_data_list)}")
    typer.echo(f"Unique Request Types: {len(combined_request_types)}")
    typer.echo(f"Total Requests (All Files): {total_requests_all:,}")
    
    if total_requests_all > 0:
        success_rate_combined = ((total_requests_all - total_errors_all) / total_requests_all * 100)
        typer.echo(f"Successful Requests (All Files): {total_requests_all - total_errors_all:,} ({success_rate_combined:.1f}%)")
    
    typer.echo(f"Total Errors (All Files): {total_errors_all}")
    
    # Consistent final status message
    if total_errors_all == 0:
        typer.echo("\n✅ No errors found across all analyzed files.")
    else:
        typer.echo("\n⚠️  There were errors in the analyzed files.")

@app.command()
def analyze(
    log_files: List[Path] = typer.Argument(..., help="Path(s) to the locust log file(s) to analyze"),
    output_dir: Path = typer.Option(None, "--output-dir", "-o", help="Directory to save the chart (defaults to first log file directory)"),
    publication_ready: bool = typer.Option(False, "--publication", "-p", help="Generate publication-ready plots with academic styling"),
    export_svg: bool = typer.Option(False, "--svg", help="Also export SVG format for better LaTeX compatibility"),
    metric_type: str = typer.Option("average", "--metric-type", "-m", help="Response time metric to plot ('average' or 'median')", case_sensitive=False),
    scatter_plot: bool = typer.Option(False, "--scatter-plot", help="Generate scatter/line plot of response times over time instead of bar charts")
):
    """
    Analyze one or more locust log files and create visualizations showing:
    1. Bar charts: Average or median response times per request type (with request counts displayed)
       and total number of errors by category
    2. Scatter plots: Response times over relative time with error markers (--scatter-plot option)
    
    When multiple files are provided, data from all files will be plotted
    in the same chart with different colors/patterns to distinguish between files.
    
    Features:
    - Bar chart mode: Total request count in title, request counts within bars, 
      choice between average and median response times
    - Scatter plot mode: Response times plotted over relative time, errors shown as red X markers
    - Publication-ready styling and SVG export options
    """
    
    # Validate metric type
    metric_type_lower = metric_type.lower()
    if metric_type_lower not in ['average', 'median']:
        typer.echo(f"Error: Invalid metric type '{metric_type}'. Must be 'average' or 'median'.", err=True)
        raise typer.Exit(1)
    
    # Validate input files
    for log_file in log_files:
        if not log_file.exists():
            typer.echo(f"Error: Log file '{log_file}' does not exist.", err=True)
            raise typer.Exit(1)
        
        if not log_file.is_file():
            typer.echo(f"Error: '{log_file}' is not a file.", err=True)
            raise typer.Exit(1)
    
    # Set output directory
    if output_dir is None:
        output_dir = log_files[0].parent  # Use first file's directory
    else:
        output_dir.mkdir(parents=True, exist_ok=True)
    
    # Consistent message format for all cases
    typer.echo(f"Analyzing {len(log_files)} log file(s):")
    for log_file in log_files:
        typer.echo(f"  - {log_file}")
    
    typer.echo(f"Output directory: {output_dir}")
    
    # Parse all log files using the multi-file parser
    typer.echo("\nParsing log files...")
    file_data_list = parse_multiple_log_files(log_files)
    
    # Check if any files have data
    has_data = False
    for file_data in file_data_list:
        if file_data.response_times or file_data.error_stats.total_errors > 0:
            has_data = True
            break
    
    if not has_data:
        typer.echo("No response time data or errors found in any log file.")
        typer.echo("Please check the log file formats.")
        raise typer.Exit(1)
    
    # Create and save charts using appropriate chart function
    if scatter_plot:
        typer.echo("\nCreating scatter plot...")
        create_scatter_plot(file_data_list, output_dir, 
                          publication_ready=publication_ready, 
                          export_svg=export_svg)
    else:
        typer.echo("\nCreating bar charts...")
        # Use consistent styling for all cases (simplified for better readability)
        create_multi_file_bar_chart(file_data_list, output_dir, omit_request_count_per_bar_labels=True, 
                                   simple_title=True, publication_ready=publication_ready, 
                                   export_svg=export_svg, metric_type=metric_type_lower)
    
    # Print summary using multi-file summary function
    print_multi_file_summary(file_data_list, metric_type_lower)
    
    typer.echo(f"\n✅ Analysis complete! Results saved to {output_dir}")

if __name__ == "__main__":
    app()
