import unittest

from generate_multivalley import generate, validate


class GraphTests(unittest.TestCase):
    def test_connectivity_sizes_and_reproducibility(self):
        for n, valleys in [(1, 1), (5, 1), (23, 4), (100, 10), (100, 100)]:
            for mode in ("isolated", "sparse", "redundant"):
                with self.subTest(n=n, valleys=valleys, mode=mode):
                    graph = generate(n, valleys, 42, mode)
                    self.assertEqual(len(graph["settlements"]), n)
                    self.assertEqual(validate(graph), valleys if mode == "isolated" else 1)
                    self.assertEqual(graph, generate(n, valleys, 42, mode))

    def test_comparisons_preserve_local_world(self):
        isolated = generate(100, 10, 42, "isolated")
        sparse = generate(100, 10, 42, "sparse")
        redundant = generate(100, 10, 42, "redundant")
        self.assertEqual(isolated["settlements"], sparse["settlements"])
        self.assertEqual(sparse["settlements"], redundant["settlements"])
        self.assertEqual(sparse["edges"][:len(isolated["edges"])], isolated["edges"])
        self.assertEqual(redundant["edges"][:len(sparse["edges"])], sparse["edges"])
        self.assertNotEqual(isolated["settlements"], generate(100, 10, 43)["settlements"])

    def test_invalid_configuration(self):
        for n, valleys in [(0, 1), (5, 0), (5, 6), (10001, 1)]:
            with self.assertRaises(ValueError):
                generate(n, valleys)


if __name__ == "__main__":
    unittest.main()
