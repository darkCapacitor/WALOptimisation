-- First, define a CTE to get the next payment date in a set-based fashion
WITH CalendarCTE AS (
    SELECT 
        AsAtDate, 
        [Month], 
        [Year], 
        RegionCode, 
        IsWorkingDay
    FROM [dbo].[syn_Model_tbl_Dim_Calendar]
    WHERE RegionCode = 'UK' AND IsWorkingDay = 1
), 

RecursiveRepayments AS 
(
    -- Anchor query: Start with the initial values
    SELECT
        @FacilityId AS FacilityId,
        @BalanceAmt AS BalanceAmt,
        @RepaymentInterest AS RepaymentInterest,
        @IsFirstPayment AS IsFirstPayment,
        @Sequence AS Sequence,
        @NextPaymentDate AS NextPaymentDate,
        @InterestAppliedToCode AS InterestAppliedToCode,
        @EffIntRate AS EffIntRate,
        @RepayPeriodMths AS RepayPeriodMths,
        @CurrentSequence AS CurrentSequence,
        @ExpiryDate AS ExpiryDate,
        @RepaymentAmt AS RepaymentAmt,
        0 AS InterestAmt,
        @NextInterestSequence AS NextInterestSequence,
        CASE WHEN @IsFirstPayment = 1 THEN @NextPaymentDate ELSE DATEADD(MONTH, @RepayPeriodMths, @NextPaymentDate) END AS NextPayment,
        0 AS IsFirstIteration -- Track whether this is the first iteration
     
    UNION ALL
    
    -- Recursive query: Continue until the balance is non-negative
    SELECT
        r.FacilityId,
        CASE
            -- Adjust balance based on the next payment date
            WHEN r.ExpiryDate > r.NextPayment THEN r.BalanceAmt + r.RepaymentAmt
            ELSE r.BalanceAmt
        END AS BalanceAmt,
        CASE 
            -- Reset interest after each payment
            WHEN r.ExpiryDate > r.NextPayment THEN r.RepaymentInterest
            ELSE 0.0
        END AS RepaymentInterest,
        0 AS IsFirstPayment, -- After the first payment, this should always be 0
        r.Sequence + r.RepayPeriodMths AS Sequence,
        -- Join with the CalendarCTE to get the next working day payment date
        c.AsAtDate AS NextPaymentDate,
        r.InterestAppliedToCode,
        r.EffIntRate,
        r.RepayPeriodMths,
        r.CurrentSequence + 1 AS CurrentSequence,
        r.ExpiryDate,
        r.RepaymentAmt,
        CASE
            -- Calculate the interest amount based on the sequence
            WHEN r.InterestAppliedToCode = '1' AND r.NextInterestSequence = r.CurrentSequence THEN 
                r.BalanceAmt * r.EffIntRate * 90 / 36500
            ELSE 0
        END AS InterestAmt,
        r.NextInterestSequence + CASE WHEN r.InterestAppliedToCode = '1' AND r.NextInterestSequence = r.CurrentSequence THEN 3 ELSE 0 END,
        DATEADD(MONTH, r.RepayPeriodMths, r.NextPayment) AS NextPayment,
        r.IsFirstIteration + 1
    FROM RecursiveRepayments r
    -- Join with CalendarCTE to get the appropriate payment date for the next sequence
    INNER JOIN CalendarCTE c
        ON c.[Month] = MONTH(r.NextPayment)
        AND c.[Year] = YEAR(r.NextPayment)
        AND c.AsAtDate <= r.ExpiryDate
    WHERE r.BalanceAmt < 0
)

-- Insert repayment schedules from the recursive CTE into the temporary table
INSERT INTO DW.CAU_RepaymentsSchedules_TEMP (FacilityId, RepaymentAmt, BalanceAmt, NextPaymentDate)
SELECT 
    FacilityId, 
    ABS(BalanceAmt) + RepaymentInterest, 
    CASE 
        WHEN BalanceAmt > 0 OR ExpiryDate <= NextPaymentDate THEN 0 
        ELSE ABS(BalanceAmt) 
    END,
    NextPaymentDate
FROM RecursiveRepayments
OPTION (MAXRECURSION 0);
