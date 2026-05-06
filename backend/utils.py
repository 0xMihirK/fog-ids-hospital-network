"""
utils.py — Math helpers for simulation, IDS, and statistics.
Vectorized with numpy for performance across 800-node network.
"""

import numpy as np
from collections import deque


def poisson_sample(lam, size=1):
    """Poisson-distributed random samples (vectorized)."""
    return np.random.poisson(lam, size=size)


def ewma_update(old_mean, old_std, new_val, alpha):
    """
    Exponentially Weighted Moving Average update (vectorized).
    Returns updated (mean, std) arrays.
    """
    new_mean = (1 - alpha) * old_mean + alpha * new_val
    new_std = (1 - alpha) * old_std + alpha * np.abs(new_val - old_mean)
    return new_mean, new_std


def z_score(value, mean, std, eps=1e-6):
    """Z-score computation (vectorized). Returns absolute Z-scores."""
    return np.abs(value - mean) / (std + eps)


def cusum_update(cusum_pos, cusum_neg, deviation, slack=1.5):
    """
    CUSUM (Cumulative Sum) update for change-point detection (vectorized).
    Returns updated (cusum_pos, cusum_neg).
    """
    cusum_pos = np.maximum(0, cusum_pos + deviation - slack)
    cusum_neg = np.maximum(0, cusum_neg - deviation - slack)
    return cusum_pos, cusum_neg


def shannon_entropy(values, eps=1e-6):
    """
    Shannon entropy of a probability-like vector (per-row if 2D).
    Input values are treated as unnormalized weights.
    """
    if values.ndim == 1:
        v = np.abs(values) + eps
        v_norm = v / v.sum()
        return -np.sum(v_norm * np.log2(v_norm))
    else:
        # Per-row entropy for 2D array
        v = np.abs(values) + eps
        row_sums = v.sum(axis=1, keepdims=True)
        v_norm = v / row_sums
        return -np.sum(v_norm * np.log2(v_norm), axis=1)


def simple_hash(data):
    """
    Fast non-cryptographic hash for packet sequence fingerprinting.
    Accepts a numpy array or list, returns an integer hash.
    """
    if isinstance(data, np.ndarray):
        return hash(data.tobytes())
    return hash(tuple(data))


class SlidingWindow:
    """Fixed-size sliding window for temporal correlation."""

    def __init__(self, size, n_items):
        self.size = size
        self.buffer = np.zeros((n_items, size), dtype=bool)
        self.ptr = 0

    def push(self, values):
        """Push a boolean array into the window at current position."""
        self.buffer[:, self.ptr] = values
        self.ptr = (self.ptr + 1) % self.size

    def mean(self):
        """Fraction of True values across the window for each item."""
        return self.buffer.mean(axis=1)

    def reset(self):
        """Clear all window data."""
        self.buffer[:] = False
        self.ptr = 0


def dynamic_fog_threshold(cluster_size):
    """
    Dynamic fog-level alarm threshold.
    Normalizes false alarm rates across heterogeneous cluster sizes.
    threshold = max(0.15, 3 / cluster_size)
    """
    if cluster_size <= 0:
        return 1.0
    return max(0.15, 3.0 / cluster_size)


def compute_anomaly_score(z_pkt, z_lat, cusum_pos, cusum_neg,
                          cusum_thresh, entropy_ratio, vital_violations,
                          n_modules=7):
    """
    Composite anomaly score in [0, 1] range (vectorized).
    Combines all detection module outputs into a single score.
    """
    score = (
        z_pkt / 8.0
        + z_lat / 5.0
        + (cusum_pos + cusum_neg) / (2.0 * cusum_thresh)
        + np.maximum(0, 1.0 - entropy_ratio)
        + vital_violations / 4.0
    ) / n_modules
    return np.clip(score, 0.0, 1.0)


def distance_matrix(x1, y1, x2, y2):
    """
    Compute pairwise Euclidean distances between two sets of points.
    Returns matrix of shape (len(x1), len(x2)).
    """
    dx = x1[:, np.newaxis] - x2[np.newaxis, :]
    dy = y1[:, np.newaxis] - y2[np.newaxis, :]
    return np.sqrt(dx ** 2 + dy ** 2)


def nearest_assignment(source_xy, target_xy):
    """
    Assign each source point to its nearest target point.
    Returns (assignments, distances) arrays.
    """
    dists = distance_matrix(
        source_xy[:, 0], source_xy[:, 1],
        target_xy[:, 0], target_xy[:, 1]
    )
    assignments = np.argmin(dists, axis=1)
    min_dists = dists[np.arange(len(assignments)), assignments]
    return assignments, min_dists
