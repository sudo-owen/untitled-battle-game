// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/**
 * @title ELO
 * @dev Simple ELO score rating system based on
 * https://en.wikipedia.org/wiki/Elo_rating_system#Mathematical_details
 */
library ELO {
    struct Score {
        uint256 score;
    }

    struct Scores {
        mapping(address => Score) scores;
    }

    /**
     * @dev Records a game result for a game between two players.
     * @param self The Scores storage
     * @param player1 Address of the first player
     * @param player2 Address of the second player
     * @param winner Address of the winner (can be address(0) to record a draw)
     */
    function recordResult(Scores storage self, address player1, address player2, address winner) internal {
        uint256 scoreA = getScore(self, player1);
        uint256 scoreB = getScore(self, player2);

        int256 resultA;
        if (winner == player1) {
            resultA = 2; // win
        } else if (winner == player2) {
            resultA = 0; // lose
        } else {
            resultA = 1; // draw
        }

        (int256 changeA, int256 changeB) = getScoreChange(int256(scoreA) - int256(scoreB), resultA);
        setScore(self, player1, uint256(int256(scoreA) + changeA));
        setScore(self, player2, uint256(int256(scoreB) + changeB));
    }

    /**
     * @dev Calculates the score change for both players based on their score difference and the game result.
     * @param difference The difference between the players' scores
     * @param resultA The result for player A (0 = lose, 1 = draw, 2 = win)
     * @return Score changes for player A and B
     */
    function getScoreChange(int256 difference, int256 resultA) internal pure returns (int256, int256) {
        bool reverse = (difference > 0);
        uint256 diff = abs(difference);

        int256 scoreChange;
        if (diff > 636) scoreChange = 20;
        else if (diff > 436) scoreChange = 19;
        else if (diff > 338) scoreChange = 18;
        else if (diff > 269) scoreChange = 17;
        else if (diff > 214) scoreChange = 16;
        else if (diff > 168) scoreChange = 15;
        else if (diff > 126) scoreChange = 14;
        else if (diff > 88) scoreChange = 13;
        else if (diff > 52) scoreChange = 12;
        else if (diff > 17) scoreChange = 11;
        else scoreChange = 10;

        if (resultA == 2) {
            return (reverse ? 20 - scoreChange : scoreChange,
                    reverse ? -scoreChange : -(20 - scoreChange));
        } else if (resultA == 1) {
            return (reverse ? 10 - scoreChange : scoreChange - 10,
                    reverse ? -(10 - scoreChange) : -(scoreChange - 10));
        } else {
            return (reverse ? scoreChange - 20 : -scoreChange,
                    reverse ? scoreChange : -(scoreChange - 20));
        }
    }

    /**
     * @dev Calculates the absolute value of an int256
     * @param value The input value
     * @return The absolute value as a uint256
     */
    function abs(int256 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(value) : uint256(-value);
    }

    /**
     * @dev Get current score for a player
     * @param self The Scores storage
     * @param player The address of the player
     * @return The player's current score (minimum 100)
     */
    function getScore(Scores storage self, address player) internal view returns (uint256) {
        return self.scores[player].score < 100 ? 100 : self.scores[player].score;
    }

    /**
     * @dev Set score for a player
     * @param self The Scores storage
     * @param player The address of the player
     * @param score The new score to set
     */
    function setScore(Scores storage self, address player, uint256 score) internal {
        self.scores[player].score = score < 100 ? 100 : score;
    }
}
